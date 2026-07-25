import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class GemmaModel {
    enum RuntimeState: Equatable {
        case missingModel
        case idle
        case downloading(String, Double)
        case loading
        case ready
        case responding
        case failed(String)

        var title: String {
            switch self {
            case .missingModel:
                "Import a Gemma 4 model"
            case .idle:
                "Model selected"
            case .downloading(let name, _):
                "Downloading \(name)"
            case .loading:
                "Loading model"
            case .ready:
                "Ready"
            case .responding:
                "Generating"
            case .failed:
                "Runtime error"
            }
        }
    }

    struct ChatMessage: Identifiable, Equatable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        var text: String
        var imageURL: URL?
        var sampleIndex: Int?
        var sampleTotal: Int?
        var elapsedDuration: Duration?
    }

    var prompt = ""
    var messages: [ChatMessage] = []
    var state: RuntimeState = .missingModel
    var modelURL: URL?
    var localModels: [LocalModel] = []
    var selectedImageURL: URL?
    var sampleCount = 1
    var totalComputeDuration: Duration?

    private let modelManager = ModelManager()
    private let modelInit = ModelInit()
    private let imageStore: ImageStore
    private var ownedImageURLs: Set<URL> = []

    init(imageStore: ImageStore = .shared) {
        self.imageStore = imageStore
    }

    var canSend: Bool {
        state == .ready && (selectedImageURL != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var selectedImageName: String? {
        selectedImageURL?.lastPathComponent
    }

    var modelName: String {
        modelURL?.lastPathComponent ?? "No model selected"
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .loading, .responding:
            true
        case .missingModel, .idle, .ready, .failed:
            false
        }
    }

    var downloadProgress: Double? {
        if case .downloading(_, let progress) = state {
            progress
        } else {
            nil
        }
    }

    func prepareForLaunch() async {
        try? await imageStore.removeOrphans(keeping: ownedImageURLs)
    }

    func refreshLocalModels() async {
        let result = modelManager.refreshLocalModels(currentModelURL: modelURL)
        let didChangeSelection = !ModelManager.sameFile(modelURL, result.selectedModelURL)

        if didChangeSelection {
            await resetRuntime()
        }

        localModels = result.models
        modelURL = result.selectedModelURL

        if modelURL == nil {
            state = .missingModel
        } else if didChangeSelection || state == .missingModel {
            state = .idle
        }
    }

    func selectModel(_ localModel: LocalModel) async {
        guard !ModelManager.sameFile(modelURL, localModel.url) else { return }

        modelURL = localModel.url
        modelManager.rememberSelectedModel(localModel.url)
        await resetRuntime()

        do {
            try await loadModel()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func downloadModel(_ model: DownloadableModel) async {
        state = .downloading(model.displayName, 0)
        await resetRuntime()

        do {
            let downloadedURL = try await modelManager.download(model: model) { progress in
                await MainActor.run {
                    self.state = .downloading(model.displayName, progress)
                }
            }
            modelURL = downloadedURL
            modelManager.rememberSelectedModel(downloadedURL)
            await refreshLocalModels()
            try await loadModel()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func importModel(from selectedURL: URL) async {
        state = .loading

        do {
            let copiedURL = try await modelManager.importModel(from: selectedURL)
            modelURL = copiedURL
            modelManager.rememberSelectedModel(copiedURL)
            await refreshLocalModels()
            await resetRuntime()
            try await loadModel()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func attachImage(data: Data) async {
        do {
            let imageURL = try await imageStore.store(data: data)
            await replaceAttachedImage(with: imageURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func attachImage(image: UIImage) async {
        do {
            let imageURL = try await imageStore.store(image: image)
            await replaceAttachedImage(with: imageURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func removeAttachedImage() async {
        guard let imageURL = selectedImageURL else { return }
        selectedImageURL = nil
        ownedImageURLs.remove(imageURL)
        await imageStore.remove([imageURL])
    }

    func loadModel() async throws {
        guard let modelURL else {
            state = .missingModel
            return
        }

        if modelInit.hasEngine(for: modelURL) {
            state = .ready
            return
        }

        state = .loading
        _ = try await modelInit.loadEngine(for: modelURL)
        state = .ready
    }

    func sendPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageURL = selectedImageURL
        guard imageURL != nil || !text.isEmpty else { return }
        let samples = max(1, min(sampleCount, 20))

        do {
            let sampler = try await loadedSampler()
            try await send(text, imageURL: imageURL, sampleCount: samples, sampler: sampler)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func resetConversation() async {
        messages.removeAll()
        totalComputeDuration = nil
        await removeAllSessionImages()

        guard let modelURL else {
            state = .missingModel
            return
        }

        state = modelInit.hasEngine(for: modelURL) ? .ready : .idle
    }

    private func loadedSampler() async throws -> Sampler {
        guard let modelURL else {
            state = .missingModel
            throw URLError(.fileDoesNotExist)
        }

        state = .loading
        let sampler = try await modelInit.loadSampler(for: modelURL)
        state = .ready
        return sampler
    }

    private func resetRuntime() async {
        modelInit.reset()
        messages.removeAll()
        totalComputeDuration = nil
        await removeAllSessionImages()
    }

    private func send(_ text: String, imageURL: URL?, sampleCount: Int, sampler: Sampler) async throws {
        prompt = ""
        selectedImageURL = nil
        totalComputeDuration = .zero
        let staleImageURLs = ownedImageURLs.subtracting(imageURL.map { [$0] } ?? [])
        ownedImageURLs.subtract(staleImageURLs)
        await imageStore.remove(staleImageURLs)
        messages.removeAll()
        messages.append(ChatMessage(role: .user, text: text, imageURL: imageURL))
        state = .responding

        try await sampler.run(
            text: text,
            imageURL: imageURL,
            sampleCount: sampleCount,
            onSampleStarted: { sampleNumber, sampleTotal in
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: "",
                        sampleIndex: sampleNumber,
                        sampleTotal: sampleTotal,
                        elapsedDuration: .zero
                    )
                )
                return messages.index(before: messages.endIndex)
            },
            onTextDelta: { responseIndex, text in
                messages[responseIndex].text += text
            },
            onTextComplete: { responseIndex, text in
                messages[responseIndex].text = text
            },
            onTimingUpdate: { responseIndex, sampleElapsed, totalElapsed in
                self.messages[responseIndex].elapsedDuration = sampleElapsed
                self.totalComputeDuration = totalElapsed
            },
            onSampleFinished: { responseIndex, sampleElapsed, totalElapsed in
                messages[responseIndex].elapsedDuration = sampleElapsed
                totalComputeDuration = totalElapsed

                if messages[responseIndex].text.isEmpty {
                    messages[responseIndex].text = "No response returned."
                }
            }
        )

        state = .ready
    }

    private func replaceAttachedImage(with imageURL: URL) async {
        let previousImageURL = selectedImageURL
        selectedImageURL = imageURL
        ownedImageURLs.insert(imageURL)

        if let previousImageURL {
            ownedImageURLs.remove(previousImageURL)
            await imageStore.remove([previousImageURL])
        }
    }

    private func removeAllSessionImages() async {
        let imageURLs = ownedImageURLs
        selectedImageURL = nil
        ownedImageURLs.removeAll()
        await imageStore.remove(imageURLs)
    }
}
