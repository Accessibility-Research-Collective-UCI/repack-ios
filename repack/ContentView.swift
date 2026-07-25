import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @State private var gemmaModel = GemmaModel()
    @State private var isImporterPresented = false
    @State private var isCameraPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    private let modelType = UTType.liteRTLMModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if gemmaModel.messages.isEmpty {
                                emptyState
                            } else {
                                ForEach(gemmaModel.messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: gemmaModel.messages) { _, messages in
                        guard let lastMessage = messages.last else { return }
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }

                composer
            }
            .navigationTitle("Gemma 4")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Import Model", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        Task {
                            await gemmaModel.resetConversation()
                        }
                    } label: {
                        Label("Reset Chat", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(gemmaModel.modelURL == nil || gemmaModel.isBusy)
                }
            }
        }
        .task {
            await gemmaModel.prepareForLaunch()
            await gemmaModel.refreshLocalModels()
            guard gemmaModel.state == .idle else { return }

            do {
                try await gemmaModel.loadModel()
            } catch {
                gemmaModel.state = .failed(error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [modelType]) { result in
            switch result {
            case .success(let url):
                Task {
                    await gemmaModel.importModel(from: url)
                }
            case .failure(let error):
                gemmaModel.state = .failed(error.localizedDescription)
            }
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraImagePicker { image in
                Task {
                    await gemmaModel.attachImage(image: image)
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }

            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        gemmaModel.state = .failed("Could not read selected photo.")
                        return
                    }

                    await gemmaModel.attachImage(data: data)
                    selectedPhotoItem = nil
                } catch {
                    gemmaModel.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text(gemmaModel.state.title)
                    .font(.headline)
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if !gemmaModel.localModels.isEmpty {
                Picker("Model", selection: selectedModelPath) {
                    ForEach(gemmaModel.localModels) { model in
                        Text(model.displayName)
                            .tag(model.url.path)
                    }
                }
                .labelsHidden()
                .disabled(gemmaModel.isBusy)
            }

            if let progress = gemmaModel.downloadProgress {
                ProgressView(value: progress)
                    .frame(width: 84)
            } else if gemmaModel.state == .loading || gemmaModel.state == .responding {
                ProgressView()
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageURL = gemmaModel.selectedImageURL {
                HStack(spacing: 10) {
                    LocalImagePreview(url: imageURL)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(gemmaModel.selectedImageName ?? "Attached image")
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        Task {
                            await gemmaModel.removeAttachedImage()
                        }
                    } label: {
                        Label("Remove Image", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .disabled(gemmaModel.isBusy)
                }
            }

            HStack(spacing: 12) {
                Stepper(value: $gemmaModel.sampleCount, in: 1...10) {
                    Text("Samples: \(gemmaModel.sampleCount)")
                        .font(.subheadline)
                }
                .disabled(gemmaModel.isBusy)

                Spacer()

                if let totalComputeDuration = gemmaModel.totalComputeDuration {
                    Text("Total \(formatDuration(totalComputeDuration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Photo Library", systemImage: "photo")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(gemmaModel.isBusy)

                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        isCameraPresented = true
                    } else {
                        gemmaModel.state = .failed("Camera is not available on this device.")
                    }
                } label: {
                    Label("Camera", systemImage: "camera")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(gemmaModel.isBusy)

                TextField("Ask Gemma 4", text: $gemmaModel.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(gemmaModel.isBusy)
                    .onSubmit(sendPrompt)

                Button(action: sendPrompt) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!gemmaModel.canSend)
            }
        }
        .padding()
        .background(.background)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "memorychip")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)

            Text("Run Gemma 4 locally")
                .font(.title2.weight(.semibold))

            Text("Download a Gemma 4 LiteRT-LM bundle or import a `.litertlm` file, then send a prompt. Compatible bundles include the speculative decoding drafter and run through the Metal backend.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !gemmaModel.localModels.isEmpty {
                VStack(spacing: 8) {
                    ForEach(gemmaModel.localModels) { model in
                        Button {
                            Task {
                                await gemmaModel.selectModel(model)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.headline)
                                    Text(model.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if gemmaModel.modelURL?.path == model.url.path {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(gemmaModel.isBusy)
                    }
                }
                .frame(maxWidth: 420)
            }

            VStack(spacing: 8) {
                ForEach(DownloadableModel.allCases) { model in
                    Button {
                        Task {
                            await gemmaModel.downloadModel(model)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(.headline)
                                Text("\(model.approximateSize) • MTP speculative decoding included")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.down.circle")
                                .font(.title3)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(gemmaModel.isBusy)
                }
            }
            .frame(maxWidth: 420)

            Button {
                isImporterPresented = true
            } label: {
                Label("Import Existing Model", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(gemmaModel.isBusy)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.top, 40)
    }

    private var statusIcon: String {
        switch gemmaModel.state {
        case .missingModel:
            "tray.and.arrow.down"
        case .idle, .loading:
            "hourglass"
        case .downloading:
            "arrow.down.circle"
        case .ready:
            "checkmark.circle"
        case .responding:
            "sparkles"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private var statusDetail: String {
        switch gemmaModel.state {
        case .missingModel:
            "Download E2B or E4B, or import an existing Gemma 4 `.litertlm` file."
        case .idle:
            gemmaModel.modelName
        case .downloading(_, let progress):
            "\(Int(progress * 100))% complete. Keep the app open until the download finishes."
        case .loading:
            "Preparing `\(gemmaModel.modelName)`. First load can take a while."
        case .ready:
            gemmaModel.modelName
        case .responding:
            if let totalComputeDuration = gemmaModel.totalComputeDuration {
                "Streaming samples. Total compute \(formatDuration(totalComputeDuration))."
            } else {
                "Streaming tokens from the local model."
            }
        case .failed(let message):
            message
        }
    }

    private func sendPrompt() {
        guard gemmaModel.canSend else { return }

        Task {
            await gemmaModel.sendPrompt()
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.seconds],
                width: .narrow,
                fractionalPart: .show(length: 1)
            )
        )
    }

    private var selectedModelPath: Binding<String> {
        Binding {
            gemmaModel.modelURL?.path ?? ""
        } set: { path in
            guard let model = gemmaModel.localModels.first(where: { $0.url.path == path }) else { return }
            Task {
                await gemmaModel.selectModel(model)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: GemmaModel.ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sampleIndex = message.sampleIndex, let sampleTotal = message.sampleTotal {
                HStack(spacing: 8) {
                    Text("Sample \(sampleIndex) of \(sampleTotal)")
                    if let elapsedDuration = message.elapsedDuration {
                        Text(formatDuration(elapsedDuration))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if let imageURL = message.imageURL {
                LocalImagePreview(url: imageURL)
                    .frame(maxWidth: 220, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Text(message.text.isEmpty ? " " : message.text)
                .textSelection(.enabled)
        }
        .padding(12)
        .foregroundColor(message.role == .assistant ? .primary : .white)
        .background(message.role == .assistant ? Color.secondary.opacity(0.14) : Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 640, alignment: message.role == .assistant ? .leading : .trailing)
    }

    private func formatDuration(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.seconds],
                width: .narrow,
                fractionalPart: .show(length: 1)
            )
        )
    }
}

private struct LocalImagePreview: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            image = nil

            do {
                image = try await ImageStore.shared.preview(at: url)
            } catch is CancellationError {
                // The view is displaying a different image now.
            } catch {
                image = nil
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.18)
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImagePicked: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImagePicked = onImagePicked
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

#Preview {
    ContentView()
}

private extension UTType {
    static let liteRTLMModel = UTType(importedAs: "com.uci.repack.litertlm")
}
