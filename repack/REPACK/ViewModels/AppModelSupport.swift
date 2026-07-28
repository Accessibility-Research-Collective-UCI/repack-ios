import Accessibility
import Foundation

extension AppModel {
    func loadSelectedModel() async {
        guard !isLoadingPipeline else { return }
        guard let modelURL else {
            phase = .missingModel
            return
        }
        guard supportsModel(at: modelURL) else {
            fail(PipelineError.e4BUnavailableOnDevice)
            return
        }

        phase = .loadingModel
        errorMessage = nil
        isLoadingPipeline = true
        defer { isLoadingPipeline = false }
        do {
            guard let processingModelURL = ModelLibrary.processingModelURL(
                for: modelURL,
                availableModels: localModels
            ) else {
                throw PipelineError.missingE2BProcessingModel
            }

            pipeline = try await REPACKPipeline(
                samplingModelURL: modelURL,
                processingModelURL: processingModelURL,
                engineFactory: engineFactory,
                devicePolicy: devicePolicy,
                embeddingProvider: EmbeddingModelResources.available().map {
                    EmbeddingGemmaService(resources: $0)
                }
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

    func discardPipelineAndRun() async {
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
        MemoryDiagnostics.log("Pipeline discarded")
    }

    func replaceAttachedImage(with imageURL: URL) async throws {
        let previousImageURL = selectedImageURL
        guard previousImageURL != imageURL else { return }

        clearPendingCaptionRun()
        invalidateCompletedResult()
        selectedImageURL = imageURL
        ownedImageURLs.insert(imageURL)

        switch phase {
        case .interrupted, .failed:
            result = nil
            progress = nil
            completedElapsed = nil
            errorMessage = nil
            pipeline?.discardCurrentRun()
            phase = pipeline == nil ? .missingModel : .ready
        default:
            break
        }

        if let previousImageURL {
            ownedImageURLs.remove(previousImageURL)
            await imageStore.remove([previousImageURL])
        }
    }

    func invalidateCompletedResult() {
        guard hasCompletedResult else { return }

        thresholdRequestID = UUID()
        thresholdTask?.cancel()
        thresholdTask = nil
        result = nil
        progress = nil
        processStartedAt = nil
        completedElapsed = nil
        isRegenerating = false
        errorMessage = nil
        pipeline?.discardCurrentRun()

        if pipeline != nil {
            phase = .ready
        } else {
            phase = .missingModel
        }
    }

    func resetCaptionState() {
        thresholdRequestID = UUID()
        thresholdTask?.cancel()
        thresholdTask = nil
        result = nil
        progress = nil
        promptChoice = .describe
        customPrompt = ""
        sampleCount = 5
        scoringMetric = defaultScoringMetric
        threshold = scoringMetric.threshold.defaultValue
        processStartedAt = nil
        completedElapsed = nil
        isRegenerating = false
        errorMessage = nil
        pipeline?.discardCurrentRun()

        if pipeline != nil {
            phase = .ready
        } else {
            phase = .missingModel
        }
    }

    func finishTiming() {
        if let processStartedAt {
            completedElapsed = processStartedAt.duration(to: clock.now)
            self.processStartedAt = nil
        }
    }

    func beginProcessing(
        runID: UUID,
        pipeline: REPACKPipeline,
        image: URL,
        prompt: CaptionPrompt,
        count: Int,
        threshold requestedThreshold: Double,
        scoringMetric: ScoringMetric
    ) {
        guard currentRunID == runID, processTask == nil else { return }

        processTask = Task { [weak self] in
            guard let self else { return }

            do {
                let generatedResult = try await pipeline.process(
                    image: image,
                    samplePrompt: prompt,
                    sampleCount: count,
                    threshold: requestedThreshold,
                    scoringMetric: scoringMetric
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

    func expireProcessing() {
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

    func interruptProcessing(message: String) async {
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

    func savePendingRun(
        image: URL,
        model: URL,
        count: Int,
        threshold: Double,
        scoringMetric: ScoringMetric
    ) {
        pendingRunStore.save(
            PendingCaptionRun(
                imageFilename: image.lastPathComponent,
                modelFilename: model.lastPathComponent,
                promptChoice: promptChoice.rawValue,
                customPrompt: customPrompt,
                sampleCount: count,
                threshold: threshold,
                scoringMetric: scoringMetric
            )
        )
        hasPendingCaptionRun = true
    }

    func restorePendingRun() async -> PendingCaptionRun? {
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
        scoringMetric = pendingRun.scoringMetric
        threshold = scoringMetric.threshold.normalized(pendingRun.threshold)
        hasPendingCaptionRun = true
        return pendingRun
    }

    func clearPendingCaptionRun() {
        pendingRunStore.clear()
        hasPendingCaptionRun = false
    }

    func fail(_ error: any Error) {
        let message = error.localizedDescription
        errorMessage = message
        phase = .failed(message)
        announce(String(localized: "REPACK failed. \(message)"))
    }

    func announceProgress(_ update: PipelineProgress) {
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

    func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
