import SwiftUI

struct ResultView: View {
    @Bindable var model: AppModel
    let result: CaptionResult
    let resetAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OutputRenderings(model: model, result: result)

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
