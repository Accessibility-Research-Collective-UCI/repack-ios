import SwiftUI

struct ResultView: View {
    @Bindable var model: AppModel
    let result: CaptionResult
    let resetAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(result.caption)
                    .font(.title2)
                    .textSelection(.enabled)
                    .accessibilityLabel("Result: \(result.caption)")

                if model.isRegenerating {
                    HStack {
                        ProgressView()
                        Text("Updating caption…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding()
            .background(.quaternary, in: .rect(cornerRadius: 20))

            SimilarityThresholdControl(
                metric: result.scoringMetric,
                value: model.threshold,
                onChange: model.updateThreshold
            )

            DetailsView(
                result: result,
                visionModelName: model.selectedModelName,
                verificationModelName: model.verificationModelName,
                prompt: model.promptDisplayText
            )

            Button(action: resetAction) {
                Label("Caption Another Image", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
