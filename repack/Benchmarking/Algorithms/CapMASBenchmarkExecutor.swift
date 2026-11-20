#if BENCHMARKING
import Foundation

@MainActor
final class CapMASBenchmarkExecutor: BenchmarkAlgorithmExecuting {
    nonisolated static let sampleCount = 1
    nonisolated static let verificationThreshold = 0.5
    nonisolated static let classificationMethod = "randomBinary"

    private let prompt: String
    private let visionEngine: any InferenceEngine
    private let textEngine: any InferenceEngine
    private let clock = ContinuousClock()

    init(
        visionModelURL: URL,
        textModelURL: URL,
        prompt: String,
        engineFactory: any EngineFactory
    ) async throws {
        self.prompt = prompt
        try engineFactory.validateModel(at: visionModelURL)
        try engineFactory.validateModel(at: textModelURL)
        visionEngine = try await engineFactory.makeVisionEngine(modelURL: visionModelURL)
        textEngine = try await engineFactory.makeTextEngine(modelURL: textModelURL)
    }

    func process(
        image: URL,
        progress: @escaping @MainActor (BenchmarkAlgorithmProgress) -> Void
    ) async throws -> BenchmarkImageExecutionResult {
        var timings: [String: Double] = [:]

        progress(Self.progress("captioning", fraction: 0))
        let captionStart = clock.now
        let caption = try await visionEngine.generateCaption(
            image: image,
            prompt: prompt,
            seed: 1
        )
        timings["captioning"] = captionStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("captioning", fraction: 1))

        progress(Self.progress("decomposition", fraction: 0))
        let decompositionStart = clock.now
        let propositions = try await decompose(caption)
        timings["decomposition"] = decompositionStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("decomposition", fraction: 1))

        let verificationStart = clock.now
        var verified: [CapMASPropositionMetadata] = []
        for (index, proposition) in propositions.enumerated() {
            try Task.checkCancellation()
            progress(
                Self.progress(
                    "verification",
                    fraction: Double(index) / Double(propositions.count)
                )
            )
            _ = try await visionEngine.generateCaption(
                image: image,
                prompt: "True or False? \(proposition)",
                seed: 1
            )
            // LiteRTLM does not expose True/False token logits. A random binary score
            // preserves the verification and correction latency workload only.
            let score = Double(Int.random(in: 0...1))
            verified.append(
                CapMASPropositionMetadata(
                    statement: proposition,
                    score: score,
                    isTrue: score > Self.verificationThreshold
                )
            )
            progress(
                Self.progress(
                    "verification",
                    fraction: Double(index + 1) / Double(propositions.count)
                )
            )
        }
        timings["verification"] = verificationStart.duration(to: clock.now).benchmarkSeconds

        let truePropositions = verified.filter(\.isTrue).map(\.statement)
        let falsePropositions = verified.filter { !$0.isTrue }.map(\.statement)
        progress(Self.progress("correction", fraction: 0))
        let correctionStart = clock.now
        let correction = try await textEngine.generateText(
            systemPrompt: Self.correctorSystemPrompt,
            userPrompt: Self.correctorUserPrompt(
                caption: caption,
                facts: truePropositions,
                nonFacts: falsePropositions
            )
        )
        timings["correction"] = correctionStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("correction", fraction: 1))

        return BenchmarkImageExecutionResult(
            timing: BenchmarkImageTiming(
                file: image.lastPathComponent,
                totalTime: timings.values.reduce(0, +),
                stages: timings
            ),
            metadata: BenchmarkImageMetadata(
                file: image.lastPathComponent,
                details: .capmas(
                    CapMASBenchmarkMetadata(
                        originalCaption: caption,
                        propositions: verified,
                        truePropositions: truePropositions,
                        falsePropositions: falsePropositions,
                        correctedCaption: Self.stripCorrectionDelimiters(correction)
                    )
                )
            )
        )
    }

    func cancel() async {
        await visionEngine.cancel()
        await textEngine.cancel()
    }

    private func decompose(_ caption: String) async throws -> [String] {
        var lastError: (any Error)?
        for _ in 0...5 {
            try Task.checkCancellation()
            do {
                let response = try await textEngine.generateText(
                    systemPrompt: Self.decomposeSystemPrompt,
                    userPrompt: "CAPTION: \(caption)"
                )
                let propositions = Self.parsePropositions(response)
                if !propositions.isEmpty {
                    return propositions
                }
                lastError = CapMASError.noPropositions
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CapMASError.noPropositions
    }

    nonisolated static func parsePropositions(_ response: String) -> [String] {
        response.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "```" else { return nil }
            let proposition = trimmed.replacingOccurrences(
                of: #"^\d+\.\s*"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            return proposition.isEmpty ? nil : proposition
        }
    }

    nonisolated static func stripCorrectionDelimiters(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: "###")
        guard parts.count >= 3 else {
            return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func progress(
        _ id: String,
        fraction: Double
    ) -> BenchmarkAlgorithmProgress {
        BenchmarkAlgorithmProgress(
            stage: BenchmarkAlgorithm.capmas.stages.first { $0.id == id },
            fractionCompleted: fraction
        )
    }

    private static func correctorUserPrompt(
        caption: String,
        facts: [String],
        nonFacts: [String]
    ) -> String {
        """
        Caption: \(caption)
        FACTS:
        \(facts.joined(separator: "\n"))
        NON-FACTS:
        \(nonFacts.joined(separator: "\n"))
        """
    }

    private static let decomposeSystemPrompt = """
    I want to verify if the given CAPTION is accurate. To assist with this verification, decompose the given CAPTION into atomic propositions. All parts of the caption must be broken down into propositions. The outputs should follow the following format:'1. proposition one
    2. proposition two
    3. proposition three'. For example, break down 'He is tall, thin, and pale' into '1. He is tall.
    2. He is thin.
    3. He is pale.'
    """

    private static let correctorSystemPrompt = """
    I want to create a caption that includes only facts. Please help me correct the given caption. The given caption contain things that are not true. Based on the given FACTS and NON-FACTS remove the non-factual elements from the caption. Place the revised caption between '###'.
    """
}

private enum CapMASError: LocalizedError {
    case noPropositions

    var errorDescription: String? {
        switch self {
        case .noPropositions:
            String(localized: "CapMAS could not decompose the caption after six attempts.")
        }
    }
}
#endif
