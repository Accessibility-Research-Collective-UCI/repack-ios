import PhotosUI
import SwiftUI
import UIKit

struct REPACKHomeView: View {
    @Bindable var model: REPACKViewModel
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showCamera: Bool
    @Binding var showModelManager: Bool
    let captionAction: () -> Void
    let resultsAction: () -> Void
    @State private var isModelSelectionPresented = false

    var body: some View {
        Form {
            if model.shouldOfferRestart {
                interruptedRunSection
            }
            modelSection
            imageSection
            promptSection
            samplingSection
            captionSection
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .navigationTitle("📦 REPACK")
        .sheet(isPresented: $isModelSelectionPresented) {
            ModelSelectionView(model: model)
        }
    }

    private var modelSection: some View {
        Section {
            Button {
                isModelSelectionPresented = true
            } label: {
                HStack {
                    if model.isBusy {
                        ProgressView()
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: modelIcon)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(
                                model.isEngineReady || model.phase == .output
                                    ? .green
                                    : .secondary
                            )
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading) {
                        Text("Selected Model")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let modelURL = model.modelURL {
                            Text(DownloadableModel.displayName(for: modelURL))
                                .font(.headline)
                            Text(selectedModelDetail(for: modelURL))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !model.isBusy {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Selected Model")
            .accessibilityValue(selectedModelAccessibilityValue)
            .accessibilityHint("Opens models available on this device.")
            .disabled(model.isBusy || model.selectableLocalModels.isEmpty)

            Button {
                showModelManager = true
            } label: {
                Label("Manage Installed Models", systemImage: "shippingbox")
            }
            .disabled(model.isBusy)
        } header: {
            Text("Model")
        } footer: {
            if let modelSectionPrompt {
                Text(modelSectionPrompt)
            }
        }
    }

    private var interruptedRunSection: some View {
        Section("Interrupted Caption") {
            Label {
                Text(
                    "The previous caption did not finish. Your image and settings were restored."
                )
            } icon: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .accessibilityHidden(true)
            }
        }
    }

    private var imageSection: some View {
        Section("Image") {
            VStack(spacing: 16) {
                if let imageURL = model.selectedImageURL {
                    LocalImagePreview(url: imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Selected image")

                    Divider()

                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        Task {
                            await model.removeAttachedImage()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isBusy)
                } else {
                    ContentUnavailableView(
                        "Choose an Image",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Select a photo or take a new one to begin.")
                    )
                    .frame(minHeight: 180)
                }

                Divider()

                imageButtonLayout
            }
            .padding(.vertical, 4)
        }
    }

    private var imageButtonLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                imageButtons
            }

            VStack(spacing: 12) {
                imageButtons
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var imageButtons: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("Photos", systemImage: "photo")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!model.isEngineReady)

        Button {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showCamera = true
            } else {
                model.errorMessage = String(localized: "Camera is not available on this device.")
            }
        } label: {
            Label("Camera", systemImage: "camera")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!model.isEngineReady)
    }

    private var promptSection: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack {
                    promptButtons
                }
                VStack {
                    promptButtons
                }
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
            Text("Product and Describe are built-in prompts optimized for product identification and succinct, general image descriptions, respectively. Custom lets you provide your own prompt.")
        }
    }

    @ViewBuilder
    private var promptButtons: some View {
        ForEach(REPACKViewModel.PromptChoice.allCases) { choice in
            Button(choice.title) {
                model.promptChoice = choice
            }
            .buttonStyle(.bordered)
            .tint(model.promptChoice == choice ? .accentColor : .secondary)
            .accessibilityAddTraits(model.promptChoice == choice ? .isSelected : [])
            .frame(maxWidth: .infinity)
        }
    }

    private var samplingSection: some View {
        Section {
            Slider(
                value: Binding(
                    get: { Double(model.sampleCount) },
                    set: { model.sampleCount = Int($0.rounded()) }
                ),
                in: 1...10,
                step: 1
            ) {
                Text("Augmentation samples")
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
            Text("Number of samples REPACK uses to verify information. More samples can improve verification, but will take longer.")
        }
    }

    private var captionSection: some View {
        Button(action: model.hasCompletedResult ? resultsAction : captionAction) {
            Text(captionButtonTitle)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.hasCompletedResult && !model.canCaption)
        .listRowInsets(.init(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var captionButtonTitle: LocalizedStringKey {
        if model.hasCompletedResult {
            "View Results"
        } else if model.shouldOfferRestart {
            "Restart Captioning"
        } else {
            "Caption Image"
        }
    }

    private func selectedModelDetail(for modelURL: URL) -> String {
        switch model.phase {
        case .loadingModel:
            String(localized: "Loading model on-device...")
        case .downloading(let name, let progress):
            String(localized: "Downloading \(name): \(progress, format: .percent.precision(.fractionLength(0)))")
        case .missingModel, .ready, .processing, .interrupted, .output, .failed:
            DownloadableModel.shortDescription(for: modelURL)
        }
    }

    private var selectedModelAccessibilityValue: String {
        guard let modelURL = model.modelURL else {
            return String(localized: "No model selected")
        }
        return String(
            localized:
                "\(DownloadableModel.displayName(for: modelURL)), \(selectedModelDetail(for: modelURL))"
        )
    }

    private var modelSectionPrompt: String? {
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

    private var modelIcon: String {
        switch model.phase {
        case .ready, .interrupted, .output:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .missingModel:
            "shippingbox"
        case .loadingModel, .downloading, .processing:
            "memorychip"
        }
    }
}
