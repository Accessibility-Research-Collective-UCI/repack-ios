import SwiftUI

struct CaptionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        promptSection
        sampleSection
    }

    private var promptSection: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack { promptButtons }
                VStack { promptButtons }
            }
            .disabled(!model.isEngineReady)

            if model.promptChoice == .custom {
                TextField("Caption prompt", text: $model.customPrompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textInputAutocapitalization(.sentences)
                    .disabled(!model.isEngineReady)
            }
        } header: {
            Text("Prompt")
        } footer: {
            Text("Product and Describe are built-in prompts for product identification and short general descriptions. Custom lets you provide your own prompt.")
        }
    }

    @ViewBuilder
    private var promptButtons: some View {
        ForEach(AppModel.PromptChoice.allCases) { choice in
            Button(choice.title) {
                model.promptChoice = choice
            }
            .buttonStyle(.bordered)
            .tint(model.promptChoice == choice ? .accentColor : .secondary)
            .accessibilityAddTraits(model.promptChoice == choice ? .isSelected : [])
            .frame(maxWidth: .infinity)
        }
    }

    private var sampleSection: some View {
        Section {
            Slider(
                value: Binding(
                    get: { Double(model.sampleCount) },
                    set: { model.sampleCount = Int($0.rounded()) }
                ),
                in: 1...10,
                step: 1
            ) {
                Text("Verification samples")
            } minimumValueLabel: {
                Text("1")
            } maximumValueLabel: {
                Text("10")
            }
            .accessibilityValue("\(model.sampleCount)")
            .accessibilityLabel("Verification samples")
            .accessibilityHint("More samples can improve verification but take longer.")
            .disabled(!model.isEngineReady)
        } header: {
            Text("Samples: \(model.sampleCount)")
        } footer: {
            Text("Number of samples REPACK uses to verify information. More samples can improve verification, but take longer.")
        }
    }
}
