#if BENCHMARKING
import LiteRTLM
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
                Section {
                    Stepper(
                        "Samples: \(model.sampleCount)",
                        value: $model.sampleCount,
                        in: 1...10
                    )

                    Picker("Similarity metric", selection: $model.scoringMetric) {
                        ForEach(ScoringMetric.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("REPACK Settings")
                } footer: {
                    Text(
                        "Uses REPACK’s default threshold for the selected similarity metric."
                    )
                }
            } else if model.algorithm == .taco {
                Section("TACO Settings") {
                    Stepper(
                        "Reformulations: \(model.sampleCount)",
                        value: $model.sampleCount,
                        in: 1...10
                    )
                }
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
                    "Processes 25 bundled images with a 20-second cooldown between images."
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
            let vision = InferenceEngineSettings.vision
            let text = InferenceEngineSettings.text
            VStack(alignment: .leading) {
                Text(.benchmarkVisionEngineSummary(
                    vision.backend.rawValue,
                    vision.visionBackend?.rawValue ?? String(localized: .benchmarkBackendNone),
                    String(localized: vision.mtpEnabled ? .benchmarkMTPEnabled : .benchmarkMTPDisabled)
                ))
                Text(.benchmarkTextEngineSummary(
                    text.backend.rawValue,
                    text.visionBackend?.rawValue ?? String(localized: .benchmarkBackendNone),
                    String(localized: text.mtpEnabled ? .benchmarkMTPEnabled : .benchmarkMTPDisabled)
                ))
            }
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
