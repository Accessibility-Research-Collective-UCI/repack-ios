import Accessibility
import Foundation
import Observation
import SwiftUI
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
        case interrupted(String)
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
    private(set) var hasPendingCaptionRun = false
    private let modelManager: ModelManager
    private let imageStore: ImageStore
    private let engineFactory: any REPACKEngineFactory
    private let devicePolicy: REPACKDevicePolicy
    private let captionExecutionCoordinator: any CaptionExecutionCoordinating
    private let pendingRunStore: any PendingCaptionRunStoring
    private let clock = ContinuousClock()
    private var pipeline: REPACK?
    private var processTask: Task<Void, Never>?
    private var thresholdTask: Task<Void, Never>?
    private var ownedImageURLs: Set<URL> = []
    private var processStartedAt: ContinuousClock.Instant?
    private var completedElapsed: Duration?
    private var thresholdRequestID = UUID()
    private var currentRunID: UUID?
    private var executionMode: CaptionExecutionMode?
    private var isLoadingPipeline = false

    init(
        modelManager: ModelManager? = nil,
        imageStore: ImageStore = .shared,
        engineFactory: (any REPACKEngineFactory)? = nil,
        devicePolicy: REPACKDevicePolicy = .current,
        captionExecutionCoordinator: any CaptionExecutionCoordinating =
            CaptionExecutionCoordinator.shared,
        pendingRunStore: any PendingCaptionRunStoring =
            UserDefaultsPendingCaptionRunStore()
    ) {
        self.modelManager = modelManager ?? ModelManager()
        self.imageStore = imageStore
        self.engineFactory = engineFactory ?? LiteRTREPACKEngineFactory.shared
        self.devicePolicy = devicePolicy
        self.captionExecutionCoordinator = captionExecutionCoordinator
        self.pendingRunStore = pendingRunStore
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
        case .missingModel, .ready, .interrupted, .output, .failed:
            false
        }
    }

    var isEngineReady: Bool {
        guard pipeline != nil else { return false }
        return switch phase {
        case .ready, .interrupted, .failed:
            true
        case .missingModel, .loadingModel, .downloading, .processing, .output:
            false
        }
    }

    var canCaption: Bool {
        isEngineReady
            && selectedImageURL != nil
            && !samplePrompt.resolvedText.isEmpty
    }

    var shouldOfferRestart: Bool {
        guard phase != .processing else { return false }
        if hasPendingCaptionRun { return true }
        if case .interrupted = phase { return true }
        return false
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
        let pendingRun = await restorePendingRun()
        try? await imageStore.removeOrphans(keeping: ownedImageURLs)
        await refreshLocalModels(preferredModelFilename: pendingRun?.modelFilename)
    }

    func refreshLocalModels(preferredModelFilename: String? = nil) async {
        let refreshed = modelManager.refreshLocalModels(currentModelURL: modelURL)
        localModels = refreshed.models
        let preferredSelection = preferredModelFilename.flatMap { filename in
            refreshed.models.first { model in
                model.url.lastPathComponent == filename && supportsModel(at: model.url)
            }?.url
        }
        let supportedSelection = refreshed.selectedModelURL.flatMap { selectedURL in
            supportsModel(at: selectedURL) ? selectedURL : nil
        }
        let resolvedSelection =
            preferredSelection ?? supportedSelection ?? selectableLocalModels.first?.url
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
        clearPendingCaptionRun()
        let imageURL = selectedImageURL
        selectedImageURL = nil
        resetCaptionState()

        if let imageURL {
            ownedImageURLs.remove(imageURL)
            await imageStore.remove([imageURL])
        }
    }

    func startProcessing() {
        guard let pipeline,
              let image = selectedImageURL,
              let modelURL,
              canCaption else {
            return
        }

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
        let runID = UUID()
        currentRunID = runID
        savePendingRun(
            image: image,
            model: modelURL,
            count: count,
            threshold: requestedThreshold
        )

        let start: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.beginProcessing(
                runID: runID,
                pipeline: pipeline,
                image: image,
                prompt: prompt,
                count: count,
                threshold: requestedThreshold
            )
        }
        let expiration: @MainActor @Sendable () -> Void = { [weak self] in
            self?.expireProcessing()
        }
        executionMode = captionExecutionCoordinator.submit(
            start: start,
            expiration: expiration
        )

        if executionMode == .foregroundOnly {
            start()
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) async {
        if scenePhase == .active {
            guard pipeline == nil,
                  modelURL != nil,
                  phase == .loadingModel || phase == .missingModel else {
                return
            }
            await loadSelectedModel()
            return
        }

        guard scenePhase == .background,
              phase == .processing,
              executionMode == .foregroundOnly else {
            return
        }

        await interruptProcessing(
            message: String(
                localized:
                    "Captioning stopped because this device cannot use the GPU while REPACK is in the background."
            )
        )
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
        currentRunID = nil
        let activeProcessTask = processTask
        processTask = nil
        activeProcessTask?.cancel()
        thresholdTask?.cancel()
        thresholdTask = nil
        captionExecutionCoordinator.complete(success: false)
        executionMode = nil
        await pipeline?.cancel()
        finishTiming()
        phase = pipeline == nil ? .missingModel : .ready
        announce(String(localized: "REPACK cancelled."))
    }

    func resetRun() async {
        await cancel()
        await removeAttachedImage()
    }
}

private extension REPACKViewModel {
    private func loadSelectedModel() async {
        guard !isLoadingPipeline else { return }
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
        isLoadingPipeline = true
        defer { isLoadingPipeline = false }
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
            phase = hasPendingCaptionRun
                ? .interrupted(
                    String(
                        localized:
                            "Captioning did not finish. Restart Captioning to begin again from the start."
                    )
                )
                : .ready
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
        currentRunID = nil
        let activeProcessTask = processTask
        processTask = nil
        activeProcessTask?.cancel()
        thresholdTask?.cancel()
        captionExecutionCoordinator.complete(success: false)
        executionMode = nil
        await pipeline?.cancel()
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
        clearPendingCaptionRun()
        let previousImageURL = selectedImageURL
        selectedImageURL = imageURL
        ownedImageURLs.insert(imageURL)

        switch phase {
        case .interrupted, .failed:
            result = nil
            progress = nil
            completedElapsed = nil
            errorMessage = nil
            pipeline?.discardCurrentRun()
            phase = pipeline == nil ? .loadingModel : .ready
        default:
            break
        }

        if let previousImageURL {
            ownedImageURLs.remove(previousImageURL)
            await imageStore.remove([previousImageURL])
        }
    }

    private func resetCaptionState() {
        thresholdRequestID = UUID()
        thresholdTask?.cancel()
        thresholdTask = nil
        result = nil
        progress = nil
        promptChoice = .describe
        customPrompt = ""
        sampleCount = 5
        threshold = 0.5
        processStartedAt = nil
        completedElapsed = nil
        isRegenerating = false
        errorMessage = nil
        pipeline?.discardCurrentRun()

        if pipeline != nil {
            phase = .ready
        } else if modelURL != nil {
            phase = .loadingModel
        } else {
            phase = .missingModel
        }
    }

    private func finishTiming() {
        if let processStartedAt {
            completedElapsed = processStartedAt.duration(to: clock.now)
            self.processStartedAt = nil
        }
    }

    private func beginProcessing(
        runID: UUID,
        pipeline: REPACK,
        image: URL,
        prompt: REPACKPrompt,
        count: Int,
        threshold requestedThreshold: Double
    ) {
        guard currentRunID == runID, processTask == nil else { return }

        processTask = Task { [weak self] in
            guard let self else { return }

            do {
                let generatedResult = try await pipeline.process(
                    image: image,
                    samplePrompt: prompt,
                    sampleCount: count,
                    threshold: requestedThreshold
                ) { [weak self] update in
                    self?.progress = update
                    self?.captionExecutionCoordinator.report(update)
                    self?.announceProgress(update)
                }
                try Task.checkCancellation()
                guard currentRunID == runID else { return }

                currentRunID = nil
                processTask = nil
                executionMode = nil
                result = generatedResult
                threshold = generatedResult.threshold
                finishTiming()
                clearPendingCaptionRun()
                captionExecutionCoordinator.complete(success: true)
                phase = .output
                announce(String(localized: "Caption complete."))
            } catch is CancellationError {
                guard currentRunID == runID else { return }

                currentRunID = nil
                processTask = nil
                executionMode = nil
                finishTiming()
                captionExecutionCoordinator.complete(success: false)
                phase = .interrupted(
                    String(
                        localized:
                            "Captioning was interrupted. Restart Captioning to begin again from the start."
                    )
                )
            } catch {
                guard currentRunID == runID else { return }

                currentRunID = nil
                processTask = nil
                executionMode = nil
                finishTiming()
                captionExecutionCoordinator.complete(success: false)
                fail(error)
            }
        }
    }

    private func expireProcessing() {
        processTask?.cancel()
        Task { [weak self] in
            await self?.interruptProcessing(
                message: String(
                    localized:
                        "Captioning was stopped by the system. Restart Captioning to begin again from the start."
                )
            )
        }
    }

    private func interruptProcessing(message: String) async {
        let wasProcessing = currentRunID != nil || phase == .processing
        currentRunID = nil
        let activeProcessTask = processTask
        processTask = nil
        activeProcessTask?.cancel()
        await pipeline?.cancel()

        guard wasProcessing else { return }

        captionExecutionCoordinator.complete(success: false)
        executionMode = nil
        finishTiming()
        phase = .interrupted(message)
        announce(String(localized: "REPACK was interrupted."))
    }

    private func savePendingRun(
        image: URL,
        model: URL,
        count: Int,
        threshold: Double
    ) {
        pendingRunStore.save(
            PendingCaptionRun(
                imageFilename: image.lastPathComponent,
                modelFilename: model.lastPathComponent,
                promptChoice: promptChoice.rawValue,
                customPrompt: customPrompt,
                sampleCount: count,
                threshold: threshold
            )
        )
        hasPendingCaptionRun = true
    }

    private func restorePendingRun() async -> PendingCaptionRun? {
        guard let pendingRun = pendingRunStore.load(),
              let restoredPromptChoice = PromptChoice(rawValue: pendingRun.promptChoice),
              let imageURL = try? await imageStore.restoreImage(
                named: pendingRun.imageFilename
              ) else {
            pendingRunStore.clear()
            hasPendingCaptionRun = false
            return nil
        }

        selectedImageURL = imageURL
        ownedImageURLs.insert(imageURL)
        promptChoice = restoredPromptChoice
        customPrompt = pendingRun.customPrompt
        sampleCount = pendingRun.sampleCount
        threshold = pendingRun.threshold
        hasPendingCaptionRun = true
        return pendingRun
    }

    private func clearPendingCaptionRun() {
        pendingRunStore.clear()
        hasPendingCaptionRun = false
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
