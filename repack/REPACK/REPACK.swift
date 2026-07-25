import Foundation

@MainActor
final class REPACK {
    typealias ProgressHandler = @MainActor (REPACKProgress) -> Void

    private let modelURL: URL
    private let engineFactory: any REPACKEngineFactory
    private let clock = ContinuousClock()

    private var visionEngine: (any REPACKInferenceEngine)?
    private var cachedResult: REPACKResult?
    private var progressHandler: ProgressHandler?

    convenience init(modelURL: URL) async throws {
        try await self.init(
            modelURL: modelURL,
            engineFactory: LiteRTREPACKEngineFactory.shared
        )
    }

    init(
        modelURL: URL,
        engineFactory: any REPACKEngineFactory
    ) async throws {
        self.modelURL = modelURL
        self.engineFactory = engineFactory

        try engineFactory.validateModel(at: modelURL)
        visionEngine = try await engineFactory.makeVisionEngine(modelURL: modelURL)
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

        var timings: [REPACKStageTiming] = []

        let samplingStart = clock.now
        let captions = try await sample(image: image, prompt: samplePrompt, count: sampleCount)
        let samplingTiming = REPACKStageTiming(
            stage: .sampling,
            duration: samplingStart.duration(to: clock.now)
        )
        timings.append(samplingTiming)
        debugLog("Sampling complete in \(samplingTiming.duration).")

        let atomizingStart = clock.now
        let atomizedCaptions = try await atomize(captions: captions)
        let atomizingTiming = REPACKStageTiming(
            stage: .atomizing,
            duration: atomizingStart.duration(to: clock.now)
        )
        timings.append(atomizingTiming)
        debugLog("Atomization complete in \(atomizingTiming.duration).")

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

        let result = REPACKResult(
            captions: captions,
            atomizedCaptions: atomizedCaptions,
            scoredAtomics: scoredAtomics,
            retainedAtomics: retainedAtomics,
            caption: repackedCaption,
            threshold: threshold,
            timings: timings
        )
        cachedResult = result
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

        try await prepareVisionEngineIfNeeded()
        guard let visionEngine else {
            throw REPACKError.missingVisionEngine
        }

        var captions: [REPACKCaption] = []
        captions.reserveCapacity(count + 1)
        let total = count + 1

        for index in 0..<total {
            try Task.checkCancellation()
            emit(.sampling(completed: index, total: total))
            let text = try await visionEngine.generateCaption(
                image: image,
                prompt: promptText,
                seed: index
            )
            let caption = REPACKCaption(
                index: index,
                kind: index == 0 ? .reference : .sample,
                text: try nonempty(text)
            )
            captions.append(caption)
            debugLog(
                "Caption \(caption.index) [\(caption.kind == .reference ? "reference" : "sample"), "
                    + "seed \(index)]:\n\(caption.text)"
            )
            emit(.sampling(completed: captions.count, total: total))
        }

        return captions
    }

    func atomize(caption: String) async throws -> [String] {
        guard let visionEngine else {
            throw REPACKError.missingVisionEngine
        }
        return try await visionEngine.atomize(caption: caption)
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

        guard let visionEngine else {
            throw REPACKError.missingVisionEngine
        }

        let caption = try nonempty(try await visionEngine.repackage(atomics: retained))
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
        return updatedResult
    }

    func cancel() async {
        await visionEngine?.cancel()
    }

    func discardCurrentRun() {
        cachedResult = nil
    }
}

private extension REPACK {
    private func prepareVisionEngineIfNeeded() async throws {
        guard visionEngine == nil else { return }

        emit(.preparingVisionModel)
        visionEngine = try await engineFactory.makeVisionEngine(modelURL: modelURL)
    }

    private func atomize(
        captions: [REPACKCaption]
    ) async throws -> [REPACKAtomizedCaption] {
        var atomizedCaptions: [REPACKAtomizedCaption] = []
        atomizedCaptions.reserveCapacity(captions.count)

        for caption in captions {
            try Task.checkCancellation()
            emit(.atomizing(completed: atomizedCaptions.count, total: captions.count))
            let statements = try await atomize(caption: caption.text)
            atomizedCaptions.append(
                REPACKAtomizedCaption(caption: caption, statements: statements)
            )
            debugLog(
                "Atomized caption \(caption.index) into \(statements.count) statements:\n"
                    + statements.debugList
            )
            emit(.atomizing(completed: atomizedCaptions.count, total: captions.count))
        }

        return atomizedCaptions
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
