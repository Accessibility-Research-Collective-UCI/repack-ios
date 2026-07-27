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

            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        thresholdLabel
                        Spacer()
                        thresholdValue
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        thresholdLabel
                        thresholdValue
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Slider(
                    value: Binding(
                        get: { model.threshold },
                        set: { model.updateThreshold($0) }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .accessibilityLabel("Verification threshold")
                .accessibilityValue(
                    Text(
                        model.threshold,
                        format: .percent.precision(.fractionLength(0))
                    )
                )
                .accessibilityHint("Adjusts how consistently a detail must appear.")

                Text("A higher threshold retains only details supported more consistently across caption samples.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

    private var thresholdLabel: some View {
        Text("Verification threshold")
            .font(.headline)
    }

    private var thresholdValue: some View {
        Text(model.threshold, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
    }
}
