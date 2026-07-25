import PhotosUI
import SwiftUI
import UIKit

struct REPACKHomeView: View {
    @Bindable var model: REPACKViewModel
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showCamera: Bool
    @Binding var showModelManager: Bool
    let captionAction: () -> Void

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showModelManager = true
                } label: {
                    Label("Manage Models", systemImage: "shippingbox")
                }
            }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            HStack {
                Image(systemName: modelIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        model.isEngineReady || model.phase == .output ? .green : .secondary
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading) {
                    Text(model.selectedModelName)
                        .font(.headline)
                    Text(modelStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isBusy {
                    ProgressView()
                        .accessibilityLabel("Loading model")
                }
            }
            .accessibilityElement(children: .combine)

            if !model.selectableLocalModels.isEmpty {
                Picker("Selected model", selection: selectedModelPath) {
                    ForEach(model.selectableLocalModels) { localModel in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localModel.displayName)
                            Text(localModel.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                            .tag(localModel.url.path)
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(model.isBusy)
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
        Button(action: captionAction) {
            Text(model.shouldOfferRestart ? "Restart Captioning" : "Caption Image")
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canCaption)
        .listRowInsets(.init(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var selectedModelPath: Binding<String> {
        Binding {
            model.modelURL?.path ?? ""
        } set: { path in
            guard let selected = model.localModels.first(where: { $0.url.path == path }) else {
                return
            }
            Task {
                await model.selectModel(selected)
            }
        }
    }

    private var modelStatus: String {
        switch model.phase {
        case .missingModel:
            String(localized: "A compatible model is required.")
        case .loadingModel:
            String(localized: "Loading model on-device...")
        case .downloading(let name, let progress):
            String(localized: "Downloading \(name): \(progress, format: .percent.precision(.fractionLength(0)))")
        case .ready:
            String(localized: "Ready")
        case .processing:
            String(localized: "Processing")
        case .interrupted:
            String(localized: "Ready to restart")
        case .output:
            String(localized: "Caption complete")
        case .failed:
            model.isEngineReady
                ? String(localized: "Ready to retry")
                : String(localized: "Model unavailable")
        }
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
