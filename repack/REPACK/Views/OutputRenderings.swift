import Foundation
import SwiftUI

struct OutputRenderings: View {
    @Bindable var model: AppModel
    let result: CaptionResult
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let controller = model.outputRenderings
        VStack(alignment: .leading, spacing: 24) {
            Picker("Output rendering", selection: Binding(
                get: { controller.selection },
                set: { model.selectOutputRendering($0) }
            )) {
                ForEach(OutputRenderingsController.Rendering.allCases) { rendering in
                    Text(rendering.tabTitle)
                        .accessibilityLabel(rendering.title)
                        .tag(rendering)
                }
            }
            .pickerStyle(.segmented)

            if controller.selection != .repack {
                Text(controller.selection.title)
                    .font(.title)
                    .bold()
            }

            if controller.selection == .repack {
                Text(.captionWithCertainty(controller.displayedCertainty))
                    .font(.title)
                    .bold()
                Text(result.caption)
                    .font(.title2)
                    .textSelection(.enabled)
                VStack(alignment: .leading) {
                    Text(.requestedCertaintyValue(controller.requestedCertainty))
                    Slider(value: Binding(
                        get: { Double(controller.requestedCertainty) },
                        set: { model.updateCertainty(Int($0)) }
                    ), in: 0...100, step: 1) {
                        Text(.certainty)
                    }
                    .accessibilityValue(Text(.certaintyPercentValue(controller.requestedCertainty)))
                }
                if controller.requestedCertainty != controller.displayedCertainty,
                   controller.errors[.repack] == nil {
                    ProgressView("Updating caption…")
                }
            } else if let text = controller.captions[controller.selection] {
                Text(Self.emphasizedText(
                    text.isEmpty ? String(localized: .noStatementsAvailable) : text,
                    rendering: controller.selection
                ))
                    .font(.title2)
                    .textSelection(.enabled)
            } else if controller.errors[controller.selection] == nil {
                ProgressView(.preparingRepresentation)
            }

            if let error = controller.errors[controller.selection] {
                Text(error).foregroundStyle(.secondary)
                Button("Retry", action: model.retryOutputRendering)
            }
        }
        .task(id: "\(scenePhase)-\(controller.revision)") {
            guard scenePhase == .active, let pipeline = model.pipeline,
                  let calibration = model.calibration else { return }
            await controller.prepare(result: result, pipeline: pipeline, calibration: calibration) {
                model.result = $0
                model.threshold = $0.threshold
                model.announce(String(localized: "Caption updated."))
            }
        }
    }

    static func emphasizedText(
        _ text: String,
        rendering: OutputRenderingsController.Rendering
    ) -> AttributedString {
        let displayPrefixes = [
            String(localized: .highConfidencePrefix),
            String(localized: .mediumConfidencePrefix),
            String(localized: .lowConfidencePrefix)
        ]
        let text = rendering == .stratified ? text.components(separatedBy: "\n").map { line in
            for (prefix, displayPrefix) in zip(OutputRenderingsController.prefixes, displayPrefixes) {
                if line.hasPrefix(prefix) {
                    return displayPrefix + line.dropFirst(prefix.count)
                }
            }
            return line
        }.joined(separator: "\n") : text
        var attributed = AttributedString(text)
        let pattern: String
        switch rendering {
        case .repack:
            return attributed
        case .atomic:
            pattern = #"(?m)^[0-9]+%:"#
        case .stratified:
            let prefixes = displayPrefixes.map {
                NSRegularExpression.escapedPattern(for: $0)
            }.joined(separator: "|")
            pattern = "(?m)^(?:\(prefixes))"
        case .hedged:
            pattern = #"\[(?:appears to|appear to|seems to|seem to|possibly|might|may)\]"#
        }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return attributed
        }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: attributed),
                  let end = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
