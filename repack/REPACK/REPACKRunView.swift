import SwiftUI

struct REPACKRunView: View {
    private enum AccessibilityElement: Hashable {
        case result
        case failure
    }

    @Bindable var model: REPACKViewModel
    let resetAction: () -> Void
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityElement?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let imageURL = model.selectedImageURL {
                    LocalImagePreview(url: imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(.rect(cornerRadius: 20))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Selected image")
                }

                switch model.phase {
                case .processing:
                    processingView
                case .output:
                    outputView
                case .failed(let message):
                    ContentUnavailableView(
                        "REPACK Stopped",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .accessibilityFocused($accessibilityFocus, equals: .failure)
                    Button("Start Over", action: resetAction)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                default:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
        }
        .navigationTitle(model.phase == .output ? "Results" : "Processing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase == .processing)
        .onChange(of: model.phase) { _, phase in
            updateAccessibilityFocus(for: phase)
        }
        .toolbar {
            if model.phase == .processing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            await model.cancel()
                            resetAction()
                        }
                    }
                }
            } else if model.phase == .output {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        isResetConfirmationPresented = true
                    }
                    .accessibilityHint("Removes the current caption and image.")
                }
            }
        }
        .alert("Start Over?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Start Over", role: .destructive, action: resetAction)
        } message: {
            Text("This will remove the current image and REPACK-processed caption.")
        }
    }

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(progressTitle)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text(progressSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let fraction = progressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(progressTitle)
                    .accessibilityValue(progressValue)
            } else {
                ProgressView()
                    .accessibilityLabel(progressTitle)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let elapsed = model.elapsed {
                    LabeledContent("Elapsed", value: format(elapsed))
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var outputView: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(result.caption)
                        .font(.title2)
                        .textSelection(.enabled)
                        .accessibilityLabel("Result: \(result.caption)")
                        .accessibilityFocused($accessibilityFocus, equals: .result)

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
                    HStack {
                        Text("Verification threshold")
                            .font(.headline)
                        Spacer()
                        Text(model.threshold, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)

                    Slider(
                        value: Binding(
                            get: { model.threshold },
                            set: { newValue in
                                model.updateThreshold(newValue)
                            }
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

                    Text("A higher threshold retain only details supported more consistently across caption samples.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                REPACKDetailsView(
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

    private var progressTitle: String {
        switch model.progress {
        case .preparingVisionModel:
            String(localized: "Preparing vision model")
        case .sampling:
            String(localized: "Generating captions")
        case .preparingTextModel:
            String(localized: "Preparing text model")
        case .atomizing:
            String(localized: "Breaking down captions")
        case .scoring:
            String(localized: "Scoring similarities")
        case .repackaging:
            String(localized: "Repackaging caption")
        case nil:
            String(localized: "Preparing REPACK")
        }
    }

    private var progressModelName: String {
        switch model.progress {
        case .sampling, .preparingVisionModel:
            model.selectedModelName
        case .atomizing, .preparingTextModel, .scoring, .repackaging:
            model.verificationModelName
        case nil:
            model.selectedModelName
        }
    }

    private var progressExecutionLocation: ModelExecutionLocation {
        guard let modelURL = model.modelURL else {
            return .onDevice
        }

        switch model.progress {
        case .sampling, .preparingVisionModel, nil:
            return DownloadableModel.executionLocation(for: modelURL)
        case .atomizing, .preparingTextModel, .scoring, .repackaging:
            guard let processingModelURL = ModelManager.processingModelURL(
                for: modelURL,
                availableModels: model.localModels
            ) else {
                return .onDevice
            }
            return DownloadableModel.executionLocation(for: processingModelURL)
        }
    }

    private var progressFraction: Double? {
        switch model.progress {
        case .sampling(let completed, let total),
             .atomizing(let completed, let total),
             .scoring(let completed, let total):
            guard total > 0 else { return nil }
            return Double(completed) / Double(total)
        default:
            return nil
        }
    }

    private var progressValue: String {
        switch model.progress {
        case .sampling(let completed, let total):
            String(localized: "\(completed) of \(total) captions")
        case .atomizing(let completed, let total):
            String(localized: "\(completed) of \(total) captions")
        case .scoring(let completed, let total):
            String(localized: "\(completed) of \(total) statements")
        default:
            ""
        }
    }

    private var progressSummary: String {
        let executionLocation = progressExecutionLocation.progressDescription

        switch model.progress {
        case .sampling(let completed, let total),
             .atomizing(let completed, let total):
            let remaining = max(total - completed, 0)
            return String(
                localized:
                    "Model: \(progressModelName), running \(executionLocation)\n\(remaining) of \(total) captions remaining"
            )
        case .scoring(let completed, let total):
            let remaining = max(total - completed, 0)
            return String(
                localized:
                    "Model: \(progressModelName), running \(executionLocation)\n\(remaining) of \(total) statements remaining"
            )
        default:
            return String(
                localized: "Model: \(progressModelName), running \(executionLocation)"
            )
        }
    }

    private func format(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.minutes, .seconds],
                width: .abbreviated,
                fractionalPart: .hide
            )
        )
    }

    private func updateAccessibilityFocus(for phase: REPACKViewModel.Phase) {
        switch phase {
        case .output:
            accessibilityFocus = .result
        case .failed:
            accessibilityFocus = .failure
        default:
            accessibilityFocus = nil
        }
    }
}
