import SwiftUI

struct CaptioningSettingsSection: View {
    @Bindable var model: AppModel
    @Binding var showSelection: Bool
    @Binding var showLibrary: Bool

    var body: some View {
        let manageModelsIconColor: Color = model.isBusy ? .secondary : .accentColor

        Section {
            Button {
                showSelection = true
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        statusIcon
                        Text(presentation.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        disclosureIcon
                    }
                    modelDescription
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint("Opens models available on this device.")
            .disabled(model.isBusy || model.selectableLocalModels.isEmpty)
        } header: {
            Text("Captioning Settings")
        } footer: {
            if let prompt {
                Text(prompt)
            }
        }

        Section {
            Button {
                showLibrary = true
            } label: {
                Label {
                    Text("Manage Installed Models")
                } icon: {
                    Image(systemName: "folder")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(manageModelsIconColor)
                }
            }
            .disabled(model.isBusy)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var modelDescription: some View {
        if let modelURL = model.modelURL {
            VStack(alignment: .leading) {
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
            Image(systemName: presentation.icon)
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
        if case .downloading(let name, let progress) = model.phase {
            String(
                localized:
                    "Downloading \(name): \(progress, format: .percent.precision(.fractionLength(0)))"
            )
        } else {
            DownloadableModel.shortDescription(for: modelURL)
        }
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
            return String(localized: "Select which model to caption with.")
        }
        return String(localized: "The selected model is not loaded.")
    }

    private var presentation: ModelSelectionPresentation {
        let icon = switch model.phase {
        case .ready, .interrupted, .output: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .missingModel: "shippingbox"
        case .loadingModel, .downloading, .processing: "memorychip"
        }

        guard let modelURL = model.modelURL else {
            let title = String(localized: "Select which model to caption with")
            return ModelSelectionPresentation(
                title: title,
                accessibilityLabel: title,
                accessibilityValue: String(localized: "No model selected"),
                icon: icon
            )
        }

        let detail = detail(for: modelURL)
        let displayName = DownloadableModel.displayName(for: modelURL)
        if model.phase == .loadingModel {
            let title = String(localized: "Loading model")
            return ModelSelectionPresentation(
                title: title,
                accessibilityLabel: title,
                accessibilityValue: String(
                    localized: "\(displayName), \(detail)"
                ),
                icon: icon
            )
        }

        return ModelSelectionPresentation(
            title: String(localized: "Selected model (tap to change model)"),
            accessibilityLabel: String(localized: "Selected model"),
            accessibilityValue: String(
                localized: "\(displayName), \(detail)"
            ),
            icon: icon
        )
    }
}

private struct ModelSelectionPresentation {
    let title: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let icon: String
}
