import Foundation
import Observation

@MainActor
@Observable
final class OutputRenderingsController {
    enum Rendering: String, CaseIterable, Identifiable {
        case repack
        case atomic
        case hedged
        case stratified

        var id: Self { self }

        var title: String {
            switch self {
            case .repack:
                String(localized: "REPACK")
            case .atomic:
                String(localized: "Atomic")
            case .hedged:
                String(localized: "Hedged")
            case .stratified:
                String(localized: "Stratified")
            }
        }
    }

    private(set) var selection: Rendering = .repack
    private(set) var hedgedCaption: String?
    private(set) var stratifiedCaptions: [StratificationTier: String] = [:]
    private(set) var isGenerating = false
    private(set) var errorMessage: String?

    private var generationTask: Task<Void, Never>?
    private var requestID = UUID()
    private var hedgedThreshold: Double?
    private var stratificationIsCached = false

    func select(
        _ rendering: Rendering,
        result: CaptionResult,
        pipeline: REPACKPipeline,
        model: DownloadableModel
    ) {
        selection = rendering
        errorMessage = nil

        switch rendering {
        case .repack, .atomic:
            cancelGeneration()
        case .hedged:
            generateHedged(result: result, pipeline: pipeline)
        case .stratified:
            generateStratified(result: result, pipeline: pipeline, model: model)
        }
    }

    func refresh(
        result: CaptionResult,
        pipeline: REPACKPipeline,
        model: DownloadableModel
    ) {
        select(selection, result: result, pipeline: pipeline, model: model)
    }

    func invalidateHedged() {
        hedgedCaption = nil
        hedgedThreshold = nil
        if selection == .hedged {
            cancelGeneration()
        }
    }

    func reset() {
        cancelGeneration()
        selection = .repack
        hedgedCaption = nil
        stratifiedCaptions = [:]
        errorMessage = nil
        hedgedThreshold = nil
        stratificationIsCached = false
    }

    func configurePreview(
        selection: Rendering,
        hedgedCaption: String? = nil,
        stratifiedCaptions: [StratificationTier: String] = [:],
        isGenerating: Bool = false,
        errorMessage: String? = nil
    ) {
        cancelGeneration()
        self.selection = selection
        self.hedgedCaption = hedgedCaption
        self.stratifiedCaptions = stratifiedCaptions
        self.isGenerating = isGenerating
        self.errorMessage = errorMessage
    }

    private func generateHedged(
        result: CaptionResult,
        pipeline: REPACKPipeline
    ) {
        guard hedgedThreshold != result.threshold || hedgedCaption == nil else { return }

        let removed = result.scoredAtomics.compactMap { atomic in
            atomic.averageScore < result.threshold ? atomic.statement : nil
        }
        guard !removed.isEmpty else {
            cancelGeneration()
            hedgedCaption = nil
            hedgedThreshold = result.threshold
            return
        }

        startGeneration { [weak self] requestID in
            let caption = try await pipeline.hedge(atomics: removed)
            try Task.checkCancellation()
            guard let self, self.requestID == requestID else { return }
            self.hedgedCaption = caption
            self.hedgedThreshold = result.threshold
        }
    }

    private func generateStratified(
        result: CaptionResult,
        pipeline: REPACKPipeline,
        model: DownloadableModel
    ) {
        guard !stratificationIsCached else { return }
        let calibration = result.scoringMetric.stratificationCalibration(for: model)

        startGeneration { [weak self] requestID in
            var captions: [StratificationTier: String] = [:]
            for tier in StratificationTier.allCases {
                let statements = result.scoredAtomics.compactMap { atomic in
                    calibration.range(for: tier).contains(atomic.averageScore)
                        ? atomic.statement
                        : nil
                }
                if !statements.isEmpty {
                    captions[tier] = try await pipeline.repackage(atomics: statements)
                }
            }
            try Task.checkCancellation()
            guard let self, self.requestID == requestID else { return }
            self.stratifiedCaptions = captions
            self.stratificationIsCached = true
        }
    }

    private func startGeneration(
        operation: @escaping @MainActor (UUID) async throws -> Void
    ) {
        cancelGeneration()
        let requestID = UUID()
        self.requestID = requestID
        isGenerating = true
        errorMessage = nil

        generationTask = Task { [weak self] in
            do {
                try await operation(requestID)
                guard let self, self.requestID == requestID else { return }
                self.isGenerating = false
                self.generationTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.requestID == requestID else { return }
                self.isGenerating = false
                self.generationTask = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelGeneration() {
        requestID = UUID()
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }
}
