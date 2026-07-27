import Foundation

@MainActor
final class REPACK {
    typealias ProgressHandler = @MainActor (REPACKProgress) -> Void

    private let samplingModelURL: URL
    private let processingModelURL: URL
    private let engineFactory: any REPACKEngineFactory
    private let devicePolicy: REPACKDevicePolicy
    private let memoryProvider: any REPACKMemoryProviding
    private let clock = ContinuousClock()

    private var samplingEngine: (any REPACKInferenceEngine)?
    private var processingEngine: (any REPACKInferenceEngine)?
    private var usesSequentialEngineLoading = false
    private var cachedResult: REPACKResult?
    private var progressHandler: ProgressHandler?

    convenience init(modelURL: URL) async throws {
        try await self.init(
            samplingModelURL: modelURL,
            processingModelURL: modelURL,
            engineFactory: LiteRTREPACKEngineFactory.shared
        )
    }

    convenience init(
        samplingModelURL: URL,
        processingModelURL: URL
    ) async throws {
        try await self.init(
            samplingModelURL: samplingModelURL,
            processingModelURL: processingModelURL,
            engineFactory: LiteRTREPACKEngineFactory.shared
        )
    }

    convenience init(
        modelURL: URL,
        engineFactory: any REPACKEngineFactory
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
        engineFactory: any REPACKEngineFactory,
        devicePolicy: REPACKDevicePolicy = .current,
        memoryProvider: any REPACKMemoryProviding = SystemREPACKMemoryProvider()
    ) async throws {
        self.samplingModelURL = samplingModelURL
        self.processingModelURL = processingModelURL
        self.engineFactory = engineFactory
        self.devicePolicy = devicePolicy
        self.memoryProvider = memoryProvider

        REPACKMemoryDiagnostics.log("Before REPACK engine initialization")
        debugLog(
            "Device \(devicePolicy.modelIdentifier) uses E4B policy "
                + "\(String(describing: devicePolicy.e4BMode))."
        )
        if ModelManager.isE4B(samplingModelURL), !devicePolicy.allowsE4B {
            throw REPACKError.e4BUnavailableOnDevice
        }

        try engineFactory.validateModel(at: samplingModelURL)
        samplingEngine = try await engineFactory.makeVisionEngine(modelURL: samplingModelURL)
        REPACKMemoryDiagnostics.log("Sampling engine ready")

        if ModelManager.sameFile(samplingModelURL, processingModelURL) {
            processingEngine = try await engineFactory.makeTextEngine(
                modelURL: processingModelURL
            )
            debugLog("Sampling and processing use separate E2B vision and MTP text engines.")
        } else {
            try engineFactory.validateModel(at: processingModelURL)
            let shouldKeepBothEnginesResident: Bool
            switch devicePolicy.e4BMode {
            case .unavailable:
                throw REPACKError.e4BUnavailableOnDevice
            case .resident:
                shouldKeepBothEnginesResident = true
            case .adaptive:
                let availableMemory = memoryProvider.availableMemory()
                shouldKeepBothEnginesResident =
                    availableMemory >= REPACKDevicePolicy.minimumAvailableForResidentEngines
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
        REPACKMemoryDiagnostics.log("REPACK engine initialization complete")
    }

    deinit {
        REPACKMemoryDiagnostics.log("REPACK deinitializing")
    }
}

extension REPACK {
    func process(
        image: URL,
        samplePrompt: REPACKPrompt,
        sampleCount: Int,
        threshold: Double,
        progress: ProgressHandler? = nil
    ) async throws -> REPACKResult {
        try validate(threshold: threshold)
        cachedResult = nil
        progressHandler = progress
        defer { progressHandler = nil }
        REPACKMemoryDiagnostics.log("Process started")

        var timings: [REPACKStageTiming] = []

        let samplingStart = clock.now
        let captions = try await sample(image: image, prompt: samplePrompt, count: sampleCount)
        let samplingTiming = REPACKStageTiming(
            stage: .sampling,
            duration: samplingStart.duration(to: clock.now)
        )
        timings.append(samplingTiming)
        debugLog("Sampling complete in \(samplingTiming.duration).")
        REPACKMemoryDiagnostics.log("Sampling stage complete")

        let atomizingStart = clock.now
        let atomizedCaptions = try await atomize(captions: captions)
        let resultCaptions = atomizedCaptions.map(\.caption)
        let atomizingTiming = REPACKStageTiming(
            stage: .atomizing,
            duration: atomizingStart.duration(to: clock.now)
        )
        timings.append(atomizingTiming)
        debugLog("Atomization complete in \(atomizingTiming.duration).")
        REPACKMemoryDiagnostics.log("Atomization stage complete")

        let scoredAtomics = try await score(
            atomizedCaptions: atomizedCaptions,
            timings: &timings
        )

        let retainedAtomics = retainedAtomics(from: scoredAtomics, threshold: threshold)
        let repackagingStart = clock.now
        let repackedCaption = try await repackage(
            referenceAtomsAndScores: scoredAtomics,
            threshold: threshold
        )
        try Task.checkCancellation()
        let repackagingTiming = REPACKStageTiming(
            stage: .repackaging,
            duration: repackagingStart.duration(to: clock.now)
        )
        timings.append(repackagingTiming)
        debugLog("Repackaging complete in \(repackagingTiming.duration).")
        REPACKMemoryDiagnostics.log("Repackaging stage complete")

        let result = REPACKResult(
            captions: resultCaptions,
            atomizedCaptions: atomizedCaptions,
            scoredAtomics: scoredAtomics,
            retainedAtomics: retainedAtomics,
            caption: repackedCaption,
            threshold: threshold,
            timings: timings
        )
        cachedResult = result
        REPACKMemoryDiagnostics.log("Process complete")
        return result
    }

    func sample(
        image: URL,
        prompt: REPACKPrompt,
        count: Int
    ) async throws -> [REPACKCaption] {
        guard 1...10 ~= count else {
            throw REPACKError.invalidSampleCount(count)
        }

        let promptText = prompt.resolvedText
        guard !promptText.isEmpty else {
            throw REPACKError.emptyPrompt
        }

        try await prepareSamplingEngineIfNeeded()
        guard let samplingEngine else {
            throw REPACKError.missingVisionEngine
        }

        var captions: [REPACKCaption] = []
        captions.reserveCapacity(count + 1)
        let total = count + 1

        for index in 0..<total {
            try Task.checkCancellation()
            emit(.sampling(completed: index, total: total))
            let seed = index + 1
            let text = try await samplingEngine.generateCaption(
                image: image,
                prompt: promptText,
                seed: seed
            )
            let caption = REPACKCaption(
                index: index,
                kind: index == 0 ? .reference : .sample,
                text: try nonempty(text)
            )
            captions.append(caption)
            debugLog(
                "Caption \(caption.index) [\(caption.kind == .reference ? "reference" : "sample"), "
                    + "seed \(seed)]:\n\(caption.text)"
            )
            REPACKMemoryDiagnostics.log("Generated caption \(caption.index) of \(total - 1)")
            emit(.sampling(completed: captions.count, total: total))
        }

        return captions
    }

    func atomize(caption: String) async throws -> REPACKAtomizationResult {
        try await prepareProcessingEngineIfNeeded()
        guard let processingEngine else {
            throw REPACKError.missingTextEngine
        }
        return try await processingEngine.atomize(caption: caption)
    }

    func score(
        referenceAtoms: [String],
        sampleAtoms: [[String]]
    ) async throws -> [REPACKScoredAtomic] {
        var results: [REPACKScoredAtomic] = []
        results.reserveCapacity(referenceAtoms.count)

        for (referenceIndex, referenceAtomic) in referenceAtoms.enumerated() {
            try Task.checkCancellation()
            emit(.scoring(completed: referenceIndex, total: referenceAtoms.count))

            var matches: [REPACKAtomicMatch] = []
            matches.reserveCapacity(sampleAtoms.count)

            for (sampleOffset, atoms) in sampleAtoms.enumerated() {
                var bestStatement: String?
                var bestScore = 0.0

                for atom in atoms {
                    let similarity = try await BLEU.compute(
                        candidate: referenceAtomic,
                        references: [atom]
                    ).bleu

                    if bestStatement == nil || similarity > bestScore {
                        bestStatement = atom
                        bestScore = similarity
                    }
                }

                matches.append(
                    REPACKAtomicMatch(
                        sampleIndex: sampleOffset + 1,
                        statement: bestStatement,
                        score: bestScore
                    )
                )
            }

            let average = matches.isEmpty
                ? 0
                : matches.reduce(0) { $0 + $1.score } / Double(matches.count)

            let scoredAtomic = REPACKScoredAtomic(
                index: referenceIndex,
                statement: referenceAtomic,
                matches: matches,
                averageScore: average
            )
            results.append(scoredAtomic)
            debugLog(scoredAtomic.debugDescription)
            emit(.scoring(completed: results.count, total: referenceAtoms.count))
        }

        debugLog("BLEU scoring complete for \(results.count) reference atomics.")
        return results
    }

    func repackage(
        referenceAtomsAndScores: [REPACKScoredAtomic],
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
            throw REPACKError.missingTextEngine
        }

        let caption = try nonempty(try await processingEngine.repackage(atomics: retained))
        debugLog("Repackaged caption:\n\(caption)")
        return caption
    }

    func regenerateCaption(threshold: Double) async throws -> REPACKResult {
        try validate(threshold: threshold)
        guard let cachedResult else {
            throw REPACKError.noCachedResult
        }

        let retained = retainedAtomics(
            from: cachedResult.scoredAtomics,
            threshold: threshold
        )
        let start = clock.now
        REPACKMemoryDiagnostics.log("Threshold regeneration started")
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
        REPACKMemoryDiagnostics.log("Threshold regeneration complete")
        return updatedResult
    }

    func cancel() async {
        await samplingEngine?.cancel()
        if let processingEngine,
           let samplingEngine,
           processingEngine !== samplingEngine {
            await processingEngine.cancel()
        }
        REPACKMemoryDiagnostics.log("Inference cancelled")
    }

    func discardCurrentRun() {
        cachedResult = nil
    }
}

private extension REPACK {
    private func prepareSamplingEngineIfNeeded() async throws {
        guard samplingEngine == nil else { return }

        if usesSequentialEngineLoading {
            await processingEngine?.cancel()
            processingEngine = nil
            REPACKMemoryDiagnostics.log("E2B processing engine released before E4B sampling")
        }

        emit(.preparingVisionModel)
        samplingEngine = try await engineFactory.makeVisionEngine(modelURL: samplingModelURL)
        REPACKMemoryDiagnostics.log("Sampling engine restored")
    }

    private func prepareProcessingEngineIfNeeded() async throws {
        guard processingEngine == nil else { return }

        if usesSequentialEngineLoading {
            await samplingEngine?.cancel()
            samplingEngine = nil
            REPACKMemoryDiagnostics.log("E4B sampling engine released before E2B processing")
        }

        emit(.preparingTextModel)
        processingEngine = try await engineFactory.makeTextEngine(modelURL: processingModelURL)
        REPACKMemoryDiagnostics.log("Processing engine restored")
    }

    private func atomize(
        captions: [REPACKCaption]
    ) async throws -> [REPACKAtomizedCaption] {
        var atomizedCaptions: [REPACKAtomizedCaption] = []
        atomizedCaptions.reserveCapacity(captions.count)

        for caption in captions {
            try Task.checkCancellation()
            emit(.atomizing(completed: atomizedCaptions.count, total: captions.count))
            let result = try await atomize(caption: caption.text)
            atomizedCaptions.append(
                REPACKAtomizedCaption(
                    caption: caption,
                    statements: result.statements,
                    status: result.status
                )
            )
            debugLog(
                "Atomized caption \(caption.index) into \(result.statements.count) statements "
                    + "[\(String(describing: result.status))]:\n"
                    + result.statements.debugList
            )
            REPACKMemoryDiagnostics.log("Atomized caption \(caption.index)")
            emit(.atomizing(completed: atomizedCaptions.count, total: captions.count))
        }

        return promotingReferenceIfNeeded(in: atomizedCaptions)
    }

    private func promotingReferenceIfNeeded(
        in atomizedCaptions: [REPACKAtomizedCaption]
    ) -> [REPACKAtomizedCaption] {
        guard let failedReference = atomizedCaptions.first,
              failedReference.status == .unparseable,
              let promotedIndex = atomizedCaptions.dropFirst().firstIndex(where: {
                  $0.status == .parsed && !$0.statements.isEmpty
              }) else {
            return atomizedCaptions
        }

        var reordered = atomizedCaptions
        let promoted = reordered[promotedIndex]

        // If the reference caption is not parsable into atomics, switch it with the first valid caption.
        reordered[0] = REPACKAtomizedCaption(
            caption: REPACKCaption(
                index: failedReference.caption.index,
                kind: .reference,
                text: promoted.caption.text
            ),
            statements: promoted.statements,
            status: promoted.status
        )
        reordered[promotedIndex] = REPACKAtomizedCaption(
            caption: REPACKCaption(
                index: promoted.caption.index,
                kind: .sample,
                text: failedReference.caption.text
            ),
            statements: failedReference.statements,
            status: failedReference.status
        )
        debugLog(
            "Promoted sample \(promoted.caption.index) after the original caption "
                + "could not be atomized."
        )
        return reordered
    }

    private func score(
        atomizedCaptions: [REPACKAtomizedCaption],
        timings: inout [REPACKStageTiming]
    ) async throws -> [REPACKScoredAtomic] {
        let start = clock.now
        let scoredAtomics = try await score(
            referenceAtoms: atomizedCaptions.first?.statements ?? [],
            sampleAtoms: atomizedCaptions.dropFirst().map(\.statements)
        )
        let timing = REPACKStageTiming(
            stage: .scoring,
            duration: start.duration(to: clock.now)
        )
        timings.append(timing)
        debugLog("Scoring complete in \(timing.duration).")
        REPACKMemoryDiagnostics.log("Scoring stage complete")
        return scoredAtomics
    }

    private func retainedAtomics(
        from scoredAtomics: [REPACKScoredAtomic],
        threshold: Double
    ) -> [String] {
        scoredAtomics.compactMap { atomic in
            atomic.averageScore >= threshold ? atomic.statement : nil
        }
    }

    private func validate(threshold: Double) throws {
        guard threshold.isFinite, 0...1 ~= threshold else {
            throw REPACKError.invalidThreshold(threshold)
        }
    }

    private func nonempty(_ response: String) throws -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw REPACKError.emptyModelResponse
        }
        return trimmed
    }

    private func emit(_ progress: REPACKProgress) {
        progressHandler?(progress)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[REPACK] \(message())")
        #endif
    }
}

private extension Array where Element == String {
    var debugList: String {
        isEmpty
            ? "  (none)"
            : enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

private extension REPACKScoredAtomic {
    var debugDescription: String {
        let formattedAverage = averageScore.formatted(
            .number.precision(.fractionLength(4))
        )
        let formattedMatches = matches.map { match in
            let score = match.score.formatted(.number.precision(.fractionLength(4)))
            return "  Sample \(match.sampleIndex): \(score) — \(match.statement ?? "(no match)")"
        }.joined(separator: "\n")

        return """
            BLEU for reference atomic \(index): \(statement)
            \(formattedMatches)
              Average: \(formattedAverage)
            """
    }
}
