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
                    .font(.headline)
            }

            if controller.selection == .repack {
                Text(.captionWithCertainty(controller.displayedCertainty))
                    .font(.headline)
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
                Text(text.isEmpty ? String(localized: .noStatementsAvailable) : text)
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
}
