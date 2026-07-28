import Foundation
import SwiftUI
import UIKit

extension AppModel {
    func prepareForLaunch() async {
        let pendingRun = await restorePendingRun()
        await modelManager.cleanDownloadStagingDirectory()
        try? await imageStore.removeOrphans(keeping: ownedImageURLs)
        await refreshLocalModels(preferredModelFilename: pendingRun?.modelFilename)
        if pendingRun == nil {
            scoringMetric = defaultScoringMetric
        }
    }

    func refreshLocalModels(preferredModelFilename: String? = nil) async {
        let refreshed = modelManager.refreshLocalModels()
        localModels = refreshed
        modelStorageItems = modelManager.storageItems(from: refreshed)
        let preferredSelection = preferredModelFilename.flatMap { filename in
            refreshed.first { model in
                model.url.lastPathComponent == filename && supportsModel(at: model.url)
            }?.url
        }
        let supportedSelection = modelURL.flatMap { selectedURL in
            refreshed.first {
                ModelLibrary.sameFile($0.url, selectedURL)
                    && supportsModel(at: $0.url)
            }?.url
        }
        let resolvedSelection = preferredSelection ?? supportedSelection
        let selectionChanged = !ModelLibrary.sameFile(modelURL, resolvedSelection)
        modelURL = resolvedSelection

        if selectionChanged {
            await discardPipelineAndRun()
        }

        if modelURL == nil || selectionChanged || pipeline == nil {
            phase = .missingModel
        }
        if scoringMetric == .semanticSimilarity,
           !isModelInstalled(.embeddingGemma) {
            scoringMetric = .bleu
        }
    }

    func selectModel(_ model: LocalModel) async {
        await prepareModelSelection(model)
        await loadPreparedModel()
    }

    func prepareModelSelection(_ model: LocalModel) async {
        guard supportsModel(at: model.url) else {
            errorMessage = PipelineError.e4BUnavailableOnDevice.localizedDescription
            return
        }

        modelManager.markExplicitOwnership(of: model)
        if ModelLibrary.sameFile(modelURL, model.url) {
            return
        }

        await discardPipelineAndRun()
        await removeAttachedImage()
        modelURL = model.url
        phase = .missingModel
    }

    func loadPreparedModel() async {
        guard pipeline == nil else { return }
        await loadSelectedModel()
    }

    func deletionSelection(
        toggling item: StorageItem,
        isSelected: Bool,
        current: Set<String>
    ) -> Set<String> {
        modelManager.deletionSelection(
            toggling: item,
            isSelected: isSelected,
            current: current,
            items: modelStorageItems
        )
    }

    func deletionPlan(for selection: Set<String>) -> DeletionPlan {
        modelManager.deletionPlan(
            selection: selection,
            items: modelStorageItems
        )
    }

    func deleteModels(_ plan: DeletionPlan) async {
        guard !isBusy, !plan.items.isEmpty else { return }

        let removesSelectedModel = plan.items.contains {
            ModelLibrary.sameFile($0.model.url, modelURL)
        }
        let removesEmbeddingModel = plan.items.contains {
            $0.record.model == .embeddingGemma
                || $0.record.model == .embeddingGemmaTokenizer
        }
        if removesSelectedModel || removesEmbeddingModel {
            await discardPipelineAndRun()
        }

        do {
            try modelManager.deleteModels(plan)
            await refreshLocalModels()
            phase = .missingModel
            announce(String(localized: "Selected models removed."))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareModelDownload(_ model: DownloadableModel) async {
        guard supportsDownload(model) else {
            errorMessage = PipelineError.e4BUnavailableOnDevice.localizedDescription
            return
        }

        do {
            let plan = try await modelManager.prepareDownloadPlan(for: model)
            if plan.files.isEmpty {
                modelDownloadAlert = .message(
                    id: UUID(),
                    title: String(localized: "Already Downloaded"),
                    message: String(
                        localized: "\(model.displayName) is already downloaded and verified."
                    )
                )
            } else {
                modelDownloadAlert = .confirmation(plan)
            }
        } catch {
            presentModelDownloadError(error)
        }
    }

    func confirmModelDownload(_ plan: DownloadPlan) async {
        guard !isModelDownloadActive else { return }

        await modelDownloadNotifier.requestAuthorizationIfNeeded()
        await discardPipelineAndRun()
        phase = .downloading(name: plan.requestedModel.displayName, progress: 0)
        modelDownloadProgress = nil
        isModelDownloadWaiting = true

        let start: @MainActor @Sendable () -> Void = { [weak self] in
            self?.beginModelDownload(plan, mode: .backgroundProtected)
        }
        let expiration: @MainActor @Sendable () -> Void = { [weak self] in
            self?.expireModelDownload()
        }
        let mode = modelDownloadExecutionCoordinator.submit(
            transactionID: plan.id,
            totalBytes: plan.totalBytes,
            start: start,
            expiration: expiration
        )

        if mode == .foregroundOnly {
            isModelDownloadWaiting = false
            finishModelDownloadWithoutLoading()
            modelDownloadAlert = .foregroundFallback(plan)
        }
    }

    func confirmForegroundModelDownload(_ plan: DownloadPlan) {
        guard !isModelDownloadActive else { return }

        phase = .downloading(name: plan.requestedModel.displayName, progress: 0)
        beginModelDownload(plan, mode: .foregroundOnly)
    }

    func cancelModelDownload() async {
        guard isModelDownloadActive else { return }

        let activeTask = modelDownloadTask
        modelDownloadTask = nil
        activeTask?.cancel()
        isModelDownloadWaiting = false
        modelDownloadProgress = nil
        finishModelDownloadWithoutLoading()
        await modelManager.cancelDownload()
        modelDownloadExecutionCoordinator.complete(success: false)
        modelDownloadExecutionMode = nil
        presentModelDownloadMessage(
            title: String(localized: "Download Cancelled"),
            message: String(localized: "The model download was cancelled.")
        )
        announce(String(localized: "Model download cancelled."))
    }

    private func beginModelDownload(
        _ plan: DownloadPlan,
        mode: ModelDownloadExecutionMode
    ) {
        guard modelDownloadTask == nil else { return }

        isModelDownloadWaiting = false
        modelDownloadExecutionMode = mode
        announce(String(localized: "Model download started."))

        modelDownloadTask = Task { [weak self] in
            guard let self else { return }

            do {
                await discardPipelineAndRun()
                try Task.checkCancellation()
                let outcome = try await modelManager.download(plan: plan) { progress in
                    await MainActor.run {
                        self.updateModelDownloadProgress(progress)
                    }
                }
                try Task.checkCancellation()

                modelDownloadExecutionCoordinator.complete(success: true)
                modelDownloadTask = nil
                modelDownloadExecutionMode = nil
                modelDownloadProgress = nil

                switch outcome {
                case .installed:
                    await refreshLocalModels()
                    if plan.requestedModel == .embeddingGemma {
                        scoringMetric = .semanticSimilarity
                    }
                case .validatedAndRemoved:
                    break
                }
                finishModelDownloadWithoutLoading()

                let message = modelDownloadCompletionMessage(for: plan)
                if UIApplication.shared.applicationState == .active {
                    presentModelDownloadMessage(
                        title: String(localized: "Download Complete"),
                        message: message
                    )
                } else {
                    let didNotify = await modelDownloadNotifier.notifyCompletion(
                        message: message
                    )
                    if !didNotify {
                        presentModelDownloadMessage(
                            title: String(localized: "Download Complete"),
                            message: message
                        )
                    }
                }
                announce(String(localized: "Model download complete."))
            } catch is CancellationError {
                guard modelDownloadTask != nil else { return }
                modelDownloadExecutionCoordinator.complete(success: false)
                modelDownloadTask = nil
                modelDownloadExecutionMode = nil
                modelDownloadProgress = nil
                finishModelDownloadWithoutLoading()
                presentModelDownloadMessage(
                    title: String(localized: "Download Cancelled"),
                    message: String(localized: "The model download was cancelled.")
                )
                announce(String(localized: "Model download cancelled."))
            } catch {
                modelDownloadExecutionCoordinator.complete(success: false)
                modelDownloadTask = nil
                modelDownloadExecutionMode = nil
                modelDownloadProgress = nil
                finishModelDownloadWithoutLoading()
                presentModelDownloadError(error)
            }
        }
    }

    private func updateModelDownloadProgress(_ progress: DownloadProgress) {
        guard modelDownloadTask != nil else { return }

        let previousModel = modelDownloadProgress?.currentModel
        modelDownloadProgress = progress
        phase = .downloading(
            name: progress.requestedModel.displayName,
            progress: progress.fractionCompleted
        )
        modelDownloadExecutionCoordinator.report(progress)

        if previousModel != nil, previousModel != progress.currentModel {
            announce(
                String(
                    localized:
                        "Starting download \(progress.fileIndex) of \(progress.fileCount): \(progress.currentModel.displayName)."
                )
            )
        }
    }

    private func expireModelDownload() {
        modelDownloadTask?.cancel()
    }

    private func finishModelDownloadWithoutLoading() {
        phase = .missingModel
    }

    private func modelDownloadCompletionMessage(
        for plan: DownloadPlan
    ) -> String {
        if plan.policy == .validateAndRemove {
            return String(
                localized:
                    "Model download test completed. Temporary files were removed."
            )
        }
        if plan.requestedModel == .e4b,
            plan.files.contains(where: { $0.model == .e2b }) {
            return String(
                localized:
                    "Gemma 4 E4B and its required model were downloaded. Select a model to load it."
            )
        }
        return String(
            localized:
                "\(plan.requestedModel.displayName) was downloaded. Select it to load it."
        )
    }

    private func presentModelDownloadError(_ error: any Error) {
        presentModelDownloadMessage(
            title: String(localized: "Download Failed"),
            message: error.localizedDescription
        )
        announce(
            String(localized: "Model download failed. \(error.localizedDescription)")
        )
    }

    private func presentModelDownloadMessage(title: String, message: String) {
        modelDownloadAlert = .message(
            id: UUID(),
            title: title,
            message: message
        )
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
        let requestedScoringMetric = scoringMetric
        let runID = UUID()
        currentRunID = runID
        savePendingRun(
            image: image,
            model: modelURL,
            count: count,
            threshold: requestedThreshold,
            scoringMetric: requestedScoringMetric
        )

        let start: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.beginProcessing(
                runID: runID,
                pipeline: pipeline,
                image: image,
                prompt: prompt,
                count: count,
                threshold: requestedThreshold,
                scoringMetric: requestedScoringMetric
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
        if scenePhase == .background,
            isModelDownloadActive,
            modelDownloadExecutionMode == .foregroundOnly {
            await cancelModelDownload()
            presentModelDownloadMessage(
                title: String(localized: "Download Stopped"),
                message: String(
                    localized:
                        "The download stopped because background downloading was unavailable. Keep the app open and try again."
                )
            )
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
                    "Captioning stopped because this device cannot run REPACK while the app is in the background."
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

    func cancelProcessing() async {
        currentRunID = nil
        let activeProcessTask = processTask
        processTask = nil
        activeProcessTask?.cancel()
        thresholdTask?.cancel()
        thresholdTask = nil
        captionExecutionCoordinator.complete(success: false)
        executionMode = nil
        await pipeline?.cancel()
        pipeline?.discardCurrentRun()
        clearPendingCaptionRun()
        result = nil
        progress = nil
        processStartedAt = nil
        completedElapsed = nil
        isRegenerating = false
        errorMessage = nil
        phase = pipeline == nil ? .missingModel : .ready
        announce(String(localized: "REPACK cancelled."))
    }

    func resetRun() async {
        await cancelProcessing()
        await removeAttachedImage()
    }
}
