#if BENCHMARKING
import SwiftUI

struct BenchmarkSetupView: View {
    @Bindable var model: BenchmarkViewModel
    let showModelManager: () -> Void

    var body: some View {
        Form {
            Section("Algorithm") {
                Picker("Algorithm", selection: $model.algorithm) {
                    ForEach(BenchmarkAlgorithm.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            engineSection

            if model.algorithm == .repack {
                REPACKBenchmarkSettingsView(model: model)
            } else if model.algorithm == .taco {
                TACOBenchmarkSettingsView(model: model)
            }

            promptSection
            preflightSection

            Section {
                Button("Start Benchmark") {
                    model.start()
                }
                .frame(maxWidth: .infinity)
                .disabled(!model.canStart)
                .accessibilityHint(
                    "Processes 25 bundled images with a 15-second cooldown between images."
                )
            }
        }
    }

    private var engineSection: some View {
        Section {
            Picker("Vision model", selection: $model.visionModel) {
                ForEach(BenchmarkCaptionModel.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityHint(
                "Uses GPU for language and vision inference. Multi-token prediction is disabled."
            )

            LabeledContent(
                "Vision model status",
                value: model.modelStatus(model.visionModel)
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Picker("Text model", selection: $model.textModel) {
                ForEach(BenchmarkCaptionModel.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityHint(
                "Uses GPU for language inference. Vision is disabled and multi-token prediction is enabled."
            )

            LabeledContent(
                "Text model status",
                value: model.modelStatus(model.textModel)
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Manage Installed Models", action: showModelManager)
        } header: {
            Text("Engine Settings")
        } footer: {
            Text(
                "Vision uses the GPU backend and GPU vision without MTP. "
                    + "Text uses the GPU backend with MTP and no vision backend."
            )
        }
    }

    private var promptSection: some View {
        Section("Captioning Prompt") {
            Picker("Prompt", selection: $model.promptType) {
                ForEach(BenchmarkPromptType.allCases) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.navigationLink)

            if model.promptType == .custom {
                TextField(
                    "Caption prompt",
                    text: $model.customPrompt,
                    axis: .vertical
                )
                .lineLimit(2...5)
            }
        }
    }

    @ViewBuilder
    private var preflightSection: some View {
        if !model.preflightMessages.isEmpty {
            Section("Before Starting") {
                ForEach(model.preflightMessages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
#endif
