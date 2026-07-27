import SwiftUI

struct HomeModelSection: View {
    let model: AppModel
    @Binding var showSelection: Bool
    @Binding var showLibrary: Bool

    var body: some View {
        Section {
            Button {
                showSelection = true
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        statusIcon
                        Text("Selected Model")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        disclosureIcon
                    }
                    modelDescription
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Selected Model")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Opens models available on this device.")
            .disabled(model.isBusy || model.selectableLocalModels.isEmpty)

            Button {
                showLibrary = true
            } label: {
                Label("Manage Installed Models", systemImage: "folder")
            }
            .disabled(model.isBusy)
        } header: {
            Text("Model")
        } footer: {
            if let prompt {
                Text(prompt)
            }
        }
    }

    @ViewBuilder
    private var modelDescription: some View {
        VStack(alignment: .leading) {
            if let modelURL = model.modelURL {
                Text(DownloadableModel.displayName(for: modelURL))
                    .font(.headline)
                Text(detail(for: modelURL))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var disclosureIcon: some View {
        if !model.isBusy {
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if model.isBusy {
            ProgressView()
                .accessibilityHidden(true)
        } else {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    model.isEngineReady || model.phase == .output
                        ? .green
                        : .secondary
                )
                .accessibilityHidden(true)
        }
    }

    private func detail(for modelURL: URL) -> String {
        switch model.phase {
        case .loadingModel:
            String(localized: "Loading model on-device...")
        case .downloading(let name, let progress):
            String(
                localized:
                    "Downloading \(name): \(progress, format: .percent.precision(.fractionLength(0)))"
            )
        case .missingModel, .ready, .processing, .interrupted, .output, .failed:
            DownloadableModel.shortDescription(for: modelURL)
        }
    }

    private var accessibilityValue: String {
        guard let modelURL = model.modelURL else {
            return String(localized: "No model selected")
        }
        return String(
            localized:
                "\(DownloadableModel.displayName(for: modelURL)), \(detail(for: modelURL))"
        )
    }

    private var prompt: String? {
        guard model.phase == .missingModel else { return nil }
        if model.localModels.isEmpty {
            return String(
                localized:
                    "No models are installed. Use Manage Installed Models to download one."
            )
        }
        if model.modelURL == nil {
            return String(localized: "Tap Selected Model to choose and load a model.")
        }
        return String(localized: "The selected model is not loaded.")
    }

    private var icon: String {
        switch model.phase {
        case .ready, .interrupted, .output: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .missingModel: "shippingbox"
        case .loadingModel, .downloading, .processing: "memorychip"
        }
    }
}
