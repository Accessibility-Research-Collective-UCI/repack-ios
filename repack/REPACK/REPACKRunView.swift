import SwiftUI

struct REPACKRunView: View {
    @Bindable var model: REPACKViewModel
    let resetAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
        .navigationTitle(model.phase == .output ? "Caption" : "Processing")
        .navigationBarBackButtonHidden(model.phase == .processing)
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
                    Button("Reset", systemImage: "arrow.counterclockwise", action: resetAction)
                }
            }
        }
    }

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: progressSymbol)
                .font(.system(.largeTitle, design: .rounded))
                .symbolEffect(.pulse)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(progressTitle)
                .font(.largeTitle.bold())

            Text(model.selectedModelName)
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

            Text("All inference stays on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var outputView: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Caption")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(result.caption)
                        .font(.title2)
                        .textSelection(.enabled)

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
                    .accessibilityValue(
                        Text(
                            model.threshold,
                            format: .percent.precision(.fractionLength(0))
                        )
                    )

                    Text("Higher values retain only details supported more consistently across samples.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                REPACKDetailsView(result: result)

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
            String(localized: "Finding atomic statements")
        case .scoring:
            String(localized: "Scoring similarities")
        case .repackaging:
            String(localized: "Repackaging caption")
        case nil:
            String(localized: "Preparing REPACK")
        }
    }

    private var progressSymbol: String {
        switch model.progress {
        case .sampling, .preparingVisionModel:
            "photo.badge.sparkles"
        case .atomizing, .preparingTextModel:
            "list.bullet.rectangle"
        case .scoring:
            "checkmark.seal"
        case .repackaging:
            "text.badge.checkmark"
        case nil:
            "sparkles"
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

    private func format(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.minutes, .seconds],
                width: .abbreviated,
                fractionalPart: .hide
            )
        )
    }
}
