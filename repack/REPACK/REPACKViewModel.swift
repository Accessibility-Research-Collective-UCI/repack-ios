import Accessibility
import Foundation
import Observation
import UIKit
@MainActor
@Observable
final class REPACKViewModel {
    enum Phase: Equatable {
        case missingModel
        case loadingModel
        case downloading(name: String, progress: Double)
        case ready
        case processing
        case output
        case failed(String)
    }
    enum PromptChoice: String, CaseIterable, Identifiable {
        case product
        case describe
        case custom

        var id: Self { self }

        var title: String {
            switch self {
            case .product:
                String(localized: "Product")
            case .describe:
                String(localized: "Describe")
            case .custom:
                String(localized: "Custom")
            }
        }
    }
    var phase: Phase = .missingModel
    var localModels: [LocalModel] = []
    var modelURL: URL?
    var selectedImageURL: URL?
    var promptChoice: PromptChoice = .describe
    var customPrompt = ""
    var sampleCount = 5
    var threshold = 0.5
    var progress: REPACKProgress?
    var result: REPACKResult?
    var isRegenerating = false
    var errorMessage: String?
    private let modelManager: ModelManager
    private let imageStore: ImageStore
    private let engineFactory: any REPACKEngineFactory
    private let devicePolicy: REPACKDevicePolicy
    private let clock = ContinuousClock()
    private var pipeline: REPACK?
    private var processTask: Task<Void, Never>?
    private var thresholdTask: Task<Void, Never>?
    private var ownedImageURLs: Set<URL> = []
    private var processStartedAt: ContinuousClock.Instant?
    private var completedElapsed: Duration?
    private var thresholdRequestID = UUID()
    init(
        modelManager: ModelManager? = nil,
        imageStore: ImageStore = .shared,
        engineFactory: (any REPACKEngineFactory)? = nil,
        devicePolicy: REPACKDevicePolicy = .current
    ) {
        self.modelManager = modelManager ?? ModelManager()
        self.imageStore = imageStore
        self.engineFactory = engineFactory ?? LiteRTREPACKEngineFactory.shared
        self.devicePolicy = devicePolicy
    }
    var selectedModelName: String {
        guard let modelURL else {
            return String(localized: "No model selected")
        }
        return DownloadableModel.displayName(for: modelURL)
    }

    var verificationModelName: String {
        guard let modelURL,
              let processingModelURL = ModelManager.processingModelURL(
                for: modelURL,
                availableModels: localModels
              ) else {
            return selectedModelName
        }
        return DownloadableModel.displayName(for: processingModelURL)
    }

    var promptDisplayText: String {
        switch promptChoice {
        case .product, .describe:
            promptChoice.title
        case .custom:
            samplePrompt.resolvedText
        }
    }

    var selectableLocalModels: [LocalModel] {
        localModels.filter { supportsModel(at: $0.url) }
    }

    func supportsModel(at url: URL) -> Bool {
        !ModelManager.isE4B(url) || devicePolicy.allowsE4B
    }

    func supportsDownload(_ model: DownloadableModel) -> Bool {
        model != .e4b || devicePolicy.allowsE4B
    }

    var isBusy: Bool {
        switch phase {
        case .loadingModel, .downloading, .processing:
            true
        case .missingModel, .ready, .output, .failed:
            false
        }
    }
    var isEngineReady: Bool {
        pipeline != nil && phase == .ready
    }

    var canCaption: Bool {
        isEngineReady
            && selectedImageURL != nil
            && !samplePrompt.resolvedText.isEmpty
    }

    var samplePrompt: REPACKPrompt {
        switch promptChoice {
        case .product:
            .product
        case .describe:
            .describe
        case .custom:
            .custom(customPrompt)
        }
    }

    var elapsed: Duration? {
        if let processStartedAt {
            processStartedAt.duration(to: clock.now)
        } else {
            completedElapsed
        }
    }
}

extension REPACKViewModel {
    func prepareForLaunch() async {
        try? await imageStore.removeOrphans(keeping: ownedImageURLs)
        await refreshLocalModels()
        guard modelURL != nil else { return }
        await loadSelectedModel()
    }

    func refreshLocalModels() async {
        let refreshed = modelManager.refreshLocalModels(currentModelURL: modelURL)
        localModels = refreshed.models
        let supportedSelection = refreshed.selectedModelURL.flatMap { selectedURL in
            supportsModel(at: selectedURL) ? selectedURL : nil
        }
        let resolvedSelection = supportedSelection ?? selectableLocalModels.first?.url
        let selectionChanged = !ModelManager.sameFile(modelURL, resolvedSelection)
        modelURL = resolvedSelection

        if let resolvedSelection, selectionChanged {
            modelManager.rememberSelectedModel(resolvedSelection)
        }

        if modelURL == nil {
            phase = .missingModel
        } else if selectionChanged {
            await discardPipelineAndRun()
            phase = .loadingModel
        }
    }

    func selectModel(_ model: LocalModel) async {
        guard supportsModel(at: model.url) else {
            errorMessage = REPACKError.e4BUnavailableOnDevice.localizedDescription
            return
        }

        if ModelManager.sameFile(modelURL, model.url) {
            if pipeline == nil {
                await loadSelectedModel()
            }
            return
        }

        await discardPipelineAndRun()
        await removeAttachedImage()
        modelURL = model.url
        modelManager.rememberSelectedModel(model.url)
        await loadSelectedModel()
    }

    func downloadModel(_ model: DownloadableModel) async {
        guard supportsDownload(model) else {
            errorMessage = REPACKError.e4BUnavailableOnDevice.localizedDescription
            return
        }

        await discardPipelineAndRun()
        phase = .downloading(name: model.displayName, progress: 0)

        do {
            let downloadedURL = try await modelManager.download(model: model) { progress in
                await MainActor.run {
                    self.phase = .downloading(name: model.displayName, progress: progress)
                }
            }
            modelURL = downloadedURL
            modelManager.rememberSelectedModel(downloadedURL)
            await refreshLocalModels()
            await loadSelectedModel()
        } catch is CancellationError {
            phase = modelURL == nil ? .missingModel : .failed(
                String(localized: "The model download was cancelled.")
            )
        } catch {
            fail(error)
        }
    }

    func importModel(from selectedURL: URL) async {
        guard supportsModel(at: selectedURL) else {
            errorMessage = REPACKError.e4BUnavailableOnDevice.localizedDescription
            return
        }

        await discardPipelineAndRun()
        phase = .loadingModel

        do {
            let importedURL = try await modelManager.importModel(from: selectedURL)
            modelURL = importedURL
            modelManager.rememberSelectedModel(importedURL)
            await refreshLocalModels()
            await loadSelectedModel()
        } catch {
            fail(error)
        }
    }

    func attachImage(data: Data) async {
        do {
            try await replaceAttachedImage(with: imageStore.store(data: data))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachImage(image: UIImage) async {
        do {
            try await replaceAttachedImage(with: imageStore.store(image: image))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAttachedImage() async {
        guard let imageURL = selectedImageURL else { return }
        selectedImageURL = nil
        ownedImageURLs.remove(imageURL)
        await imageStore.remove([imageURL])
    }

    func startProcessing() {
        guard let pipeline, let image = selectedImageURL, canCaption else { return }

        thresholdTask?.cancel()
        processTask?.cancel()
        result = nil
        progress = .sampling(completed: 0, total: sampleCount + 1)
        completedElapsed = nil
        processStartedAt = clock.now
        phase = .processing
        announce(String(localized: "REPACK started."))

        let prompt = samplePrompt
        let count = sampleCount
        let requestedThreshold = threshold
        processTask = Task {
            do {
                let generatedResult = try await pipeline.process(
                    image: image,
                    samplePrompt: prompt,
                    sampleCount: count,
                    threshold: requestedThreshold
                ) { [weak self] update in
                    self?.progress = update
                    self?.announceProgress(update)
                }
                try Task.checkCancellation()
                result = generatedResult
                threshold = generatedResult.threshold
                finishTiming()
                phase = .output
                announce(String(localized: "Caption complete."))
            } catch is CancellationError {
                finishTiming()
                phase = self.pipeline == nil ? .missingModel : .ready
            } catch {
                finishTiming()
                fail(error)
            }
        }
    }

    func updateThreshold(_ newValue: Double) {
        threshold = newValue
        guard result != nil, let pipeline else { return }

        thresholdTask?.cancel()
        thresholdRequestID = UUID()
        let requestID = thresholdRequestID

        thresholdTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
                try Task.checkCancellation()
                isRegenerating = true
                defer {
                    if requestID == thresholdRequestID {
                        isRegenerating = false
                    }
                }

                let regenerated = try await pipeline.regenerateCaption(threshold: newValue)
                try Task.checkCancellation()
                guard requestID == thresholdRequestID else { return }
                result = regenerated
                announce(String(localized: "Caption updated."))
            } catch is CancellationError {
                return
            } catch {
                guard requestID == thresholdRequestID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() async {
        processTask?.cancel()
        thresholdTask?.cancel()
        processTask = nil
        thresholdTask = nil
        await pipeline?.cancel()
        finishTiming()
        phase = pipeline == nil ? .missingModel : .ready
        announce(String(localized: "REPACK cancelled."))
    }

    func resetRun() async {
        await cancel()
        result = nil
        progress = nil
        threshold = 0.5
        completedElapsed = nil
        errorMessage = nil
        pipeline?.discardCurrentRun()
        await removeAttachedImage()
    }
}

private extension REPACKViewModel {
    private func loadSelectedModel() async {
        guard let modelURL else {
            phase = .missingModel
            return
        }
        guard supportsModel(at: modelURL) else {
            fail(REPACKError.e4BUnavailableOnDevice)
            return
        }

        phase = .loadingModel
        errorMessage = nil
        do {
            guard let processingModelURL = ModelManager.processingModelURL(
                for: modelURL,
                availableModels: localModels
            ) else {
                throw REPACKError.missingE2BProcessingModel
            }

            pipeline = try await REPACK(
                samplingModelURL: modelURL,
                processingModelURL: processingModelURL,
                engineFactory: engineFactory,
                devicePolicy: devicePolicy
            )
            phase = .ready
            announce(String(localized: "Model ready."))
        } catch is CancellationError {
            phase = .missingModel
        } catch {
            pipeline = nil
            fail(error)
        }
    }

    private func discardPipelineAndRun() async {
        thresholdRequestID = UUID()
        processTask?.cancel()
        thresholdTask?.cancel()
        await pipeline?.cancel()
        processTask = nil
        thresholdTask = nil
        pipeline = nil
        result = nil
        progress = nil
        processStartedAt = nil
        completedElapsed = nil
        isRegenerating = false
        REPACKMemoryDiagnostics.log("Pipeline discarded")
    }

    private func replaceAttachedImage(with imageURL: URL) async throws {
        let previousImageURL = selectedImageURL
        selectedImageURL = imageURL
        ownedImageURLs.insert(imageURL)

        if let previousImageURL {
            ownedImageURLs.remove(previousImageURL)
            await imageStore.remove([previousImageURL])
        }
    }

    private func finishTiming() {
        if let processStartedAt {
            completedElapsed = processStartedAt.duration(to: clock.now)
            self.processStartedAt = nil
        }
    }

    private func fail(_ error: any Error) {
        let message = error.localizedDescription
        errorMessage = message
        phase = .failed(message)
        announce(String(localized: "REPACK failed. \(message)"))
    }

    private func announceProgress(_ update: REPACKProgress) {
        let message: String?
        switch update {
        case .preparingVisionModel:
            message = String(localized: "Preparing the vision model.")
        case .sampling(let completed, let total) where completed == total:
            message = String(localized: "Caption sampling complete.")
        case .preparingTextModel:
            message = String(localized: "Preparing the text model.")
        case .atomizing(let completed, let total) where completed == total:
            message = String(localized: "Caption breakdown complete.")
        case .scoring(let completed, let total) where completed == total:
            message = String(localized: "Similarity scoring complete.")
        case .repackaging:
            message = String(localized: "Repackaging the verified statements.")
        default:
            message = nil
        }

        if let message {
            announce(message)
        }
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
