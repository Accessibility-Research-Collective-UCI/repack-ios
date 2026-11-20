import Foundation
import Observation

@MainActor
@Observable
final class OutputRenderingsController {
    enum Rendering: String, CaseIterable, Identifiable {
        case repack, atomic, stratified, hedged
        var id: Self { self }
        var tabTitle: String {
            switch self {
            case .repack: String(localized: "Caption")
            case .atomic: String(localized: .percentageStatementsTab)
            case .stratified: String(localized: .confidenceGroupsTab)
            case .hedged: String(localized: .hedgingLanguageTab)
            }
        }
        var title: String {
            switch self {
            case .repack: String(localized: "Caption")
            case .atomic: String(localized: .percentageStatements)
            case .stratified: String(localized: .confidenceGroups)
            case .hedged: String(localized: .hedgingLanguage)
            }
        }
    }

    var selection: Rendering = .repack
    private(set) var captions: [Rendering: String] = [:]
    private(set) var errors: [Rendering: String] = [:]
    private(set) var generating: Rendering?
    private(set) var displayedCertainty = 90
    var requestedCertainty = 90
    var revision = 0
    private var worker: Task<Void, Never>?
    private var epoch = UUID()
    private var confidenceGroups: [String] = []

    func reset() {
        worker?.cancel()
        epoch = UUID()
        selection = .repack
        captions = [:]
        confidenceGroups = []
        errors = [:]
        generating = nil
        displayedCertainty = 90
        requestedCertainty = 90
        revision += 1
    }

    func finishCancellation() async {
        worker?.cancel()
        await worker?.value
    }

    func retry() {
        errors[selection] = nil
        revision += 1
    }

    func setCertainty(_ value: Int) {
        requestedCertainty = min(100, max(0, value))
        errors[.repack] = nil
        revision += 1
    }

    /// Cancel and join the previous operation before using its inference engine again.
    func prepare(
        result: CaptionResult,
        pipeline: REPACKPipeline,
        calibration: ConformalCalibration,
        update: @escaping @MainActor (CaptionResult) -> Void
    ) async {
        let previous = worker
        previous?.cancel()
        let epoch = epoch
        let certainty = requestedCertainty
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.epoch == epoch, !Task.isCancelled else { return }
            defer { if self.epoch == epoch { self.generating = nil } }
            if certainty != self.displayedCertainty, self.errors[.repack] == nil {
                self.generating = .repack
                do {
                    try await Task.sleep(for: .milliseconds(600))
                    let regenerated = try await pipeline.regenerateCaption(threshold: calibration.threshold(certainty: certainty))
                    try Task.checkCancellation()
                    guard self.epoch == epoch else { return }
                    self.displayedCertainty = certainty
                    update(regenerated)
                } catch {
                    guard !Task.isCancelled, self.epoch == epoch else { return }
                    self.errors[.repack] = error.localizedDescription
                }
            }
            for rendering in [Rendering.atomic, .stratified, .hedged] {
                guard !Task.isCancelled, self.epoch == epoch else { return }
                guard self.captions[rendering] == nil, self.errors[rendering] == nil else { continue }
                self.generating = rendering
                do {
                    let text: String
                    switch rendering {
                    case .atomic:
                        text = Self.sorted(result.scoredAtomics).map {
                            "\(calibration.percentage(score: $0.averageScore))%: \($0.statement)"
                        }.joined(separator: "\n")
                    case .stratified:
                        var remaining = Self.sorted(result.scoredAtomics)
                        for index in 0..<3 {
                            let cutoff = index == 0 ? calibration.threshold(certainty: 90) : calibration.threshold(certainty: 80)
                            let group = index == 2 ? remaining : remaining.filter { $0.averageScore >= cutoff }
                            if index < 2 { remaining.removeAll { $0.averageScore >= cutoff } }
                            guard index >= self.confidenceGroups.count else { continue }
                            let text = group.isEmpty ? Self.emptyGroups[index]
                                : try await pipeline.confidenceGroup(atomics: group.map(\.statement), prefix: Self.prefixes[index])
                            try Task.checkCancellation()
                            guard self.epoch == epoch else { return }
                            self.confidenceGroups.append(text)
                        }
                        text = self.confidenceGroups.joined(separator: "\n\n")
                    case .hedged:
                        let threshold = calibration.threshold(certainty: 90)
                        let certain = result.scoredAtomics.filter { $0.averageScore > threshold }.map(\.statement)
                        let uncertain = result.scoredAtomics.filter { $0.averageScore <= threshold }.map(\.statement)
                        let caption = !certain.isEmpty && certain == result.retainedAtomics ? result.caption : try await pipeline.repackage(atomics: certain)
                        try Task.checkCancellation()
                        let hedged = try await pipeline.hedge(atomics: uncertain)
                        text = [caption, Self.markHedges(hedged)].filter { !$0.isEmpty }.joined(separator: " ")
                    case .repack: continue
                    }
                    try Task.checkCancellation()
                    guard self.epoch == epoch else { return }
                    self.captions[rendering] = text
                } catch {
                    guard !Task.isCancelled, self.epoch == epoch else { return }
                    self.errors[rendering] = error.localizedDescription
                }
            }
        }
        worker = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func sorted(_ atomics: [ScoredAtomic]) -> [ScoredAtomic] {
        atomics.enumerated().sorted {
            $0.element.averageScore == $1.element.averageScore
                ? $0.offset < $1.offset : $0.element.averageScore > $1.element.averageScore
        }.map(\.element)
    }

    static let prefixes = [
        "We think it is highly likely that",
        "We think it is somewhat likely that",
        "We are unsure whether"
    ]
    static let emptyGroups = [
        String(localized: .noHighlyLikelyInformation),
        String(localized: .noSomewhatLikelyInformation),
        String(localized: .noUnsureInformation)
    ]

    static func markHedges(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b(appears to|appear to|seems to|seem to|possibly|might|may)\b"#,
            with: "[$1]", options: [.regularExpression, .caseInsensitive]
        ).replacingOccurrences(
            of: #"([.!?])([\"”'])\s*[.!?]\s*$"#,
            with: "$1$2", options: .regularExpression
        )
    }

    func configurePreview(selection: Rendering, hedgedCaption: String? = nil,
                          stratifiedCaption: String? = nil, percentageStatements: String? = nil,
                          isGenerating: Bool = false, errorMessage: String? = nil) {
        reset()
        self.selection = selection
        captions[.hedged] = isGenerating || errorMessage != nil ? nil : hedgedCaption
        captions[.stratified] = stratifiedCaption
        captions[.atomic] = percentageStatements
        generating = isGenerating ? selection : nil
        errors[selection] = errorMessage
    }
}
