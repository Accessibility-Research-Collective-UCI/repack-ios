import Foundation

@MainActor
final class REPACKPipeline {
    typealias ProgressHandler = @MainActor (PipelineProgress) -> Void

    private let samplingModelURL: URL
    private let processingModelURL: URL
    private let engineFactory: any EngineFactory
    private let scorers: [ScoringMetric: any CaptionScorer]
    private let devicePolicy: DevicePolicy
    private let memoryProvider: any MemoryProviding
    private let clock = ContinuousClock()

    private var samplingEngine: (any InferenceEngine)?
    private var processingEngine: (any InferenceEngine)?
    private var usesSequentialEngineLoading = false
    private var cachedResult: CaptionResult?
    private var progressHandler: ProgressHandler?

    convenience init(modelURL: URL) async throws {
        try await self.init(
            samplingModelURL: modelURL,
            processingModelURL: modelURL,
            engineFactory: LiteRTEngineFactory.shared
        )
    }

    convenience init(
        samplingModelURL: URL,
        processingModelURL: URL
    ) async throws {
        try await self.init(
            samplingModelURL: samplingModelURL,
            processingModelURL: processingModelURL,
            engineFactory: LiteRTEngineFactory.shared
        )
    }

    convenience init(
        modelURL: URL,
        engineFactory: any EngineFactory
    ) async throws {
        try await self.init(
            samplingModelURL: modelURL,
            processingModelURL: modelURL,
            engineFactory: engineFactory
        )
    }

    init(
        samplingModelURL: URL,
        processingModelURL: URL,
        engineFactory: any EngineFactory,
        devicePolicy: DevicePolicy = .current,
        memoryProvider: any MemoryProviding = SystemMemoryProvider(),
        scorer: any CaptionScorer = BLEUCaptionScorer(),
        embeddingProvider: (any TextEmbeddingProviding)? = nil
    ) async throws {
        self.samplingModelURL = samplingModelURL
        self.processingModelURL = processingModelURL
        self.engineFactory = engineFactory
        self.devicePolicy = devicePolicy
        self.memoryProvider = memoryProvider
        var scorers: [ScoringMetric: any CaptionScorer] = [
            scorer.metric: scorer
        ]
        if let embeddingProvider {
            let semanticScorer = SemanticCaptionScorer(
                embeddingProvider: embeddingProvider
            )
            scorers[semanticScorer.metric] = semanticScorer
        }
        self.scorers = scorers

        MemoryDiagnostics.log("Before REPACK engine initialization")
        debugLog(
            "Device \(devicePolicy.modelIdentifier) uses E4B policy "
                + "\(String(describing: devicePolicy.e4BMode))."
        )
        if ModelLibrary.isE4B(samplingModelURL), !devicePolicy.allowsE4B {
            throw PipelineError.e4BUnavailableOnDevice
        }

        try engineFactory.validateModel(at: samplingModelURL)
        samplingEngine = try await engineFactory.makeVisionEngine(modelURL: samplingModelURL)
        MemoryDiagnostics.log("Sampling engine ready")

        if ModelLibrary.sameFile(samplingModelURL, processingModelURL) {
            processingEngine = try await engineFactory.makeTextEngine(
                modelURL: processingModelURL
            )
            debugLog("Sampling and processing use separate E2B vision and MTP text engines.")
        } else {
            try engineFactory.validateModel(at: processingModelURL)
            let shouldKeepBothEnginesResident: Bool
            switch devicePolicy.e4BMode {
            case .unavailable:
                throw PipelineError.e4BUnavailableOnDevice
            case .resident:
                shouldKeepBothEnginesResident = true
            case .adaptive:
                let availableMemory = memoryProvider.availableMemory()
                shouldKeepBothEnginesResident =
                    availableMemory >= DevicePolicy.minimumAvailableForResidentEngines
                debugLog(
                    "Adaptive engine policy found "
                        + "\(availableMemory.formatted(.byteCount(style: .memory))) available."
                )
            }

            if shouldKeepBothEnginesResident {
                processingEngine = try await engineFactory.makeTextEngine(
                    modelURL: processingModelURL
                )
                debugLog(
                    "Sampling uses \(samplingModelURL.deletingPathExtension().lastPathComponent); "
                        + "processing uses \(processingModelURL.deletingPathExtension().lastPathComponent)."
                )
            } else {
                usesSequentialEngineLoading = true
                debugLog(
                    "E4B will be released after sampling before E2B processing is loaded."
                )
            }
        }
        MemoryDiagnostics.log("REPACK engine initialization complete")
    }

    deinit {
        MemoryDiagnostics.log("REPACK deinitializing")
    }
}

extension REPACKPipeline {
    func process(
        image: URL,
        samplePrompt: CaptionPrompt,
        sampleCount: Int,
        threshold: Double,
        scoringMetric: ScoringMetric = .bleu,
        progress: ProgressHandler? = nil
    ) async throws -> CaptionResult {
        try validate(threshold: threshold)
        guard let scorer = scorers[scoringMetric] else {
            throw PipelineError.missingEmbeddingModel
        }
        cachedResult = nil
        progressHandler = progress
        defer { progressHandler = nil }
        MemoryDiagnostics.log("Process started")

        var timings: [StageTiming] = []

        let samplingStart = clock.now
        let captions = try await sample(image: image, prompt: samplePrompt, count: sampleCount)
        let samplingTiming = StageTiming(
            stage: .sampling,
            duration: samplingStart.duration(to: clock.now)
        )
        timings.append(samplingTiming)
        debugLog("Sampling complete in \(samplingTiming.duration).")
        MemoryDiagnostics.log("Sampling stage complete")

        let atomizingStart = clock.now
        let atomizationBatch = try await atomize(
            captions: captions,
            scorer: scorer
        )
        let atomizedCaptions = atomizationBatch.captions
        let resultCaptions = atomizedCaptions.map(\.caption)
        let atomizingTiming = StageTiming(
            stage: .atomizing,
            duration: atomizingStart.duration(to: clock.now)
        )
        timings.append(atomizingTiming)
        debugLog("Atomization complete in \(atomizingTiming.duration).")
        MemoryDiagnostics.log("Atomization stage complete")

        let scoredAtomics = try await score(
            atomizationBatch: atomizationBatch,
            scorer: scorer,
            timings: &timings
        )

        let retainedAtomics = retainedAtomics(from: scoredAtomics, threshold: threshold)
        let repackagingStart = clock.now
        let repackedCaption = try await repackage(
            referenceAtomsAndScores: scoredAtomics,
            threshold: threshold
        )
        try Task.checkCancellation()
        let repackagingTiming = StageTiming(
            stage: .repackaging,
            duration: repackagingStart.duration(to: clock.now)
        )
        timings.append(repackagingTiming)
        debugLog("Repackaging complete in \(repackagingTiming.duration).")
        MemoryDiagnostics.log("Repackaging stage complete")

        let result = CaptionResult(
            captions: resultCaptions,
            atomizedCaptions: atomizedCaptions,
            scoredAtomics: scoredAtomics,
            retainedAtomics: retainedAtomics,
            caption: repackedCaption,
            threshold: threshold,
            scoringMetric: scoringMetric,
            timings: timings
        )
        cachedResult = result
        MemoryDiagnostics.log("Process complete")
        return result
    }

    func sample(
        image: URL,
        prompt: CaptionPrompt,
        count: Int
    ) async throws -> [CaptionSample] {
        guard 1...10 ~= count else {
            throw PipelineError.invalidSampleCount(count)
        }

        let promptText = prompt.resolvedText
        guard !promptText.isEmpty else {
            throw PipelineError.emptyPrompt
        }

        try await prepareSamplingEngineIfNeeded()
        guard let samplingEngine else {
            throw PipelineError.missingVisionEngine
        }

        var captions: [CaptionSample] = []
        captions.reserveCapacity(count + 1)
        let total = count + 1
        let runSeed = Int32.random(in: 1...(Int32.max - Int32(total - 1)))

        for index in 0..<total {
            try Task.checkCancellation()
            emit(.sampling(completed: index, total: total))
            let seed = runSeed &+ Int32(index)
            let text = try await samplingEngine.generateCaption(
                image: image,
                prompt: promptText,
                seed: Int(seed)
            )
            let caption = CaptionSample(
                index: index,
                kind: index == 0 ? .reference : .sample,
                text: try nonempty(text)
            )
            captions.append(caption)
            debugLog(
                "Caption \(caption.index) [\(caption.kind == .reference ? "reference" : "sample"), "
                    + "seed \(seed)]:\n\(caption.text)"
            )
            MemoryDiagnostics.log("Generated caption \(caption.index) of \(total - 1)")
            emit(.sampling(completed: captions.count, total: total))
        }

        return captions
    }

    func atomize(caption: String) async throws -> AtomizationResult {
        try await prepareProcessingEngineIfNeeded()
        guard let processingEngine else {
            throw PipelineError.missingTextEngine
        }
        return try await processingEngine.atomize(caption: caption)
    }

    func repackage(
        referenceAtomsAndScores: [ScoredAtomic],
        threshold: Double
    ) async throws -> String {
        try validate(threshold: threshold)
        let retained = retainedAtomics(
            from: referenceAtomsAndScores,
            threshold: threshold
        )
        debugLog(
            "Threshold \(threshold.formatted(.number.precision(.fractionLength(2)))) retained "
                + "\(retained.count) atomics:\n\(retained.debugList)"
        )
        emit(.repackaging)

        guard !retained.isEmpty else {
            let abstention = String(
                localized: "REPACK could not verify enough details to produce a caption at this threshold."
            )
            debugLog("Repackaged caption:\n\(abstention)")
            return abstention
        }

        try await prepareProcessingEngineIfNeeded()
        guard let processingEngine else {
            throw PipelineError.missingTextEngine
        }

        let caption = try nonempty(try await processingEngine.repackage(atomics: retained))
        debugLog("Repackaged caption:\n\(caption)")
        return caption
    }

    func regenerateCaption(threshold: Double) async throws -> CaptionResult {
        try validate(threshold: threshold)
        guard let cachedResult else {
            throw PipelineError.noCachedResult
        }

        let retained = retainedAtomics(
            from: cachedResult.scoredAtomics,
            threshold: threshold
        )
        let start = clock.now
        MemoryDiagnostics.log("Threshold regeneration started")
        let caption = try await repackage(
            referenceAtomsAndScores: cachedResult.scoredAtomics,
            threshold: threshold
        )
        try Task.checkCancellation()
        let updatedResult = cachedResult.replacingRepackage(
            retainedAtomics: retained,
            caption: caption,
            threshold: threshold,
            duration: start.duration(to: clock.now)
        )
        self.cachedResult = updatedResult
        debugLog(
            "Threshold regeneration complete at "
                + "\(threshold.formatted(.number.precision(.fractionLength(2))))."
        )
        MemoryDiagnostics.log("Threshold regeneration complete")
        return updatedResult
    }

    func hedge(atomics: [String]) async throws -> String {
        guard !atomics.isEmpty else { return "" }
        try await prepareProcessingEngineIfNeeded()
        guard let processingEngine else {
            throw PipelineError.missingTextEngine
        }

        let data = try JSONEncoder().encode(atomics)
        guard let encodedAtomics = String(data: data, encoding: .utf8) else {
            throw AtomizationError.unableToEncodeInput
        }
        return try nonempty(
            try await processingEngine.generateText(
                systemPrompt: Prompts.hedgePrompt,
                userPrompt: "Unverified visual statements:\n\(encodedAtomics)"
            )
        )
    }

    func repackage(atomics: [String]) async throws -> String {
        guard !atomics.isEmpty else { return "" }
        try await prepareProcessingEngineIfNeeded()
        guard let processingEngine else {
            throw PipelineError.missingTextEngine
        }
        return try nonempty(try await processingEngine.repackage(atomics: atomics))
    }

    func cancel() async {
        await samplingEngine?.cancel()
        if let processingEngine,
           let samplingEngine,
           processingEngine !== samplingEngine {
            await processingEngine.cancel()
        }
        MemoryDiagnostics.log("Inference cancelled")
    }

    func discardCurrentRun() {
        cachedResult = nil
    }
}

private extension REPACKPipeline {
    private func prepareSamplingEngineIfNeeded() async throws {
        guard samplingEngine == nil else { return }

        if usesSequentialEngineLoading {
            await processingEngine?.cancel()
            processingEngine = nil
            MemoryDiagnostics.log("E2B processing engine released before E4B sampling")
        }

        emit(.preparingVisionModel)
        samplingEngine = try await engineFactory.makeVisionEngine(modelURL: samplingModelURL)
        MemoryDiagnostics.log("Sampling engine restored")
    }

    private func prepareProcessingEngineIfNeeded() async throws {
        guard processingEngine == nil else { return }

        if usesSequentialEngineLoading {
            await samplingEngine?.cancel()
            samplingEngine = nil
            MemoryDiagnostics.log("E4B sampling engine released before E2B processing")
        }

        emit(.preparingTextModel)
        processingEngine = try await engineFactory.makeTextEngine(modelURL: processingModelURL)
        MemoryDiagnostics.log("Processing engine restored")
    }

    private func atomize(
        captions: [CaptionSample],
        scorer: any CaptionScorer
    ) async throws -> AtomizationBatch {
        await scorer.clearPreparationCache()
        do {
            let result = try await prepareAtomics(captions: captions, scorer: scorer)
            await scorer.clearPreparationCache()
            return result
        } catch {
            await scorer.clearPreparationCache()
            throw error
        }
    }

    private func prepareAtomics(
        captions: [CaptionSample], scorer: any CaptionScorer
    ) async throws -> AtomizationBatch {
        return try await withThrowingTaskGroup(
            of: PreparedCaptionScoringInput.self
        ) { group in
            var atomizedCaptions: [AtomizedCaption] = []
            atomizedCaptions.reserveCapacity(captions.count)

            for caption in captions {
                try Task.checkCancellation()
                emit(.atomizing(completed: atomizedCaptions.count, total: captions.count))
                let result = try await atomize(caption: caption.text)
                atomizedCaptions.append(
                    AtomizedCaption(
                        caption: caption,
                        statements: result.statements,
                        status: result.status
                    )
                )
                let captionID = caption.id
                let statements = result.statements
                group.addTask {
                    try await scorer.prepare(
                        captionID: captionID,
                        statements: statements
                    )
                }
                debugLog(
                    "Atomized caption \(caption.index) into \(result.statements.count) statements "
                        + "[\(String(describing: result.status))]:\n"
                        + result.statements.debugList
                )
                MemoryDiagnostics.log("Atomized caption \(caption.index)")
                emit(.atomizing(completed: atomizedCaptions.count, total: captions.count))
            }

            var preparedByCaptionID: [Int: PreparedCaptionScoringInput] = [:]
            for try await prepared in group {
                preparedByCaptionID[prepared.captionID] = prepared
            }
            let preparedCaptions = try captions.map { caption in
                guard let prepared = preparedByCaptionID[caption.id] else {
                    throw SemanticScoringError.statementVectorCountMismatch
                }
                return prepared
            }

            return promotingReferenceIfNeeded(
                in: AtomizationBatch(
                    captions: atomizedCaptions,
                    preparedCaptions: preparedCaptions
                )
            )
        }
    }

    private func promotingReferenceIfNeeded(
        in batch: AtomizationBatch
    ) -> AtomizationBatch {
        guard let failedReference = batch.captions.first,
              failedReference.status == .unparseable,
              let promotedIndex = batch.captions.dropFirst().firstIndex(where: {
                  $0.status == .parsed && !$0.statements.isEmpty
              }) else {
            return batch
        }

        var reordered = batch.captions
        var preparedCaptions = batch.preparedCaptions
        let promoted = reordered[promotedIndex]

        // If the reference caption is not parsable into atomics, switch it with the first valid caption.
        reordered[0] = AtomizedCaption(
            caption: CaptionSample(
                index: failedReference.caption.index,
                kind: .reference,
                text: promoted.caption.text
            ),
            statements: promoted.statements,
            status: promoted.status
        )
        reordered[promotedIndex] = AtomizedCaption(
            caption: CaptionSample(
                index: promoted.caption.index,
                kind: .sample,
                text: failedReference.caption.text
            ),
            statements: failedReference.statements,
            status: failedReference.status
        )
        preparedCaptions.swapAt(0, promotedIndex)
        debugLog(
            "Promoted sample \(promoted.caption.index) after the original caption "
                + "could not be atomized."
        )
        return AtomizationBatch(
            captions: reordered,
            preparedCaptions: preparedCaptions
        )
    }

    private func score(
        atomizationBatch: AtomizationBatch,
        scorer: any CaptionScorer,
        timings: inout [StageTiming]
    ) async throws -> [ScoredAtomic] {
        let start = clock.now
        guard let reference = atomizationBatch.preparedCaptions.first else {
            return []
        }
        let scoredAtomics = try await scorer.score(
            reference: reference,
            samples: Array(atomizationBatch.preparedCaptions.dropFirst())
        ) { [weak self] completed, total in
            self?.emit(.scoring(completed: completed, total: total))
        }
        scoredAtomics.forEach {
            debugLog($0.debugDescription(metric: scorer.metric))
        }
        debugLog(
            "\(scorer.metric.title) scoring complete for "
                + "\(scoredAtomics.count) reference atomics."
        )
        let timing = StageTiming(
            stage: .scoring,
            duration: start.duration(to: clock.now)
        )
        timings.append(timing)
        debugLog("Scoring complete in \(timing.duration).")
        MemoryDiagnostics.log("Scoring stage complete")
        return scoredAtomics
    }

    private func retainedAtomics(
        from scoredAtomics: [ScoredAtomic],
        threshold: Double
    ) -> [String] {
        scoredAtomics.compactMap { atomic in
            atomic.averageScore >= threshold ? atomic.statement : nil
        }
    }

    private func validate(threshold: Double) throws {
        guard threshold.isFinite, 0...1 ~= threshold else {
            throw PipelineError.invalidThreshold(threshold)
        }
    }

    private func nonempty(_ response: String) throws -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PipelineError.emptyModelResponse
        }
        return trimmed
    }

    private func emit(_ progress: PipelineProgress) {
        progressHandler?(progress)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[REPACK] \(message())")
        #endif
    }
}

private struct AtomizationBatch {
    let captions: [AtomizedCaption]
    let preparedCaptions: [PreparedCaptionScoringInput]
}

private extension Array where Element == String {
    var debugList: String {
        isEmpty
            ? "  (none)"
            : enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

private extension ScoredAtomic {
    func debugDescription(metric: ScoringMetric = .bleu) -> String {
        let formattedAverage = averageScore.formatted(
            .number.precision(.fractionLength(4))
        )
        let formattedMatches = matches.map { match in
            let score = match.score.formatted(.number.precision(.fractionLength(4)))
            return "  Sample \(match.sampleIndex): \(score) — \(match.statement ?? "(no match)")"
        }.joined(separator: "\n")

        return """
            \(metric.title) for reference atomic \(index): \(statement)
            \(formattedMatches)
              Average: \(formattedAverage)
            """
    }
}
