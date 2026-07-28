import Foundation

nonisolated struct BLEUCaptionScorer: CaptionScorer {
    let metric = ScoringMetric.bleu

    func prepare(
        captionID: Int,
        statements: [String]
    ) async throws -> PreparedCaptionScoringInput {
        PreparedCaptionScoringInput(
            captionID: captionID,
            statements: statements
        )
    }

    @concurrent
    func score(
        reference: PreparedCaptionScoringInput,
        samples: [PreparedCaptionScoringInput],
        progress: @escaping ScoringProgressHandler
    ) async throws -> [ScoredAtomic] {
        var results: [ScoredAtomic] = []
        results.reserveCapacity(reference.statements.count)

        for (referenceIndex, referenceAtomic) in reference.statements.enumerated() {
            try Task.checkCancellation()
            await progress(referenceIndex, reference.statements.count)

            var matches: [AtomicMatch] = []
            matches.reserveCapacity(samples.count)

            for (sampleOffset, sample) in samples.enumerated() {
                var bestStatement: String?
                var bestScore = 0.0

                for atomic in sample.statements {
                    let similarity = try await BLEU.compute(
                        candidate: referenceAtomic,
                        references: [atomic]
                    ).bleu

                    if bestStatement == nil || similarity > bestScore {
                        bestStatement = atomic
                        bestScore = similarity
                    }
                }

                matches.append(
                    AtomicMatch(
                        sampleIndex: sampleOffset + 1,
                        statement: bestStatement,
                        score: bestScore
                    )
                )
            }

            let average = matches.isEmpty
                ? 0
                : matches.reduce(0) { $0 + $1.score } / Double(matches.count)
            results.append(
                ScoredAtomic(
                    index: referenceIndex,
                    statement: referenceAtomic,
                    matches: matches,
                    averageScore: average
                )
            )
            await progress(results.count, reference.statements.count)
        }

        return results
    }
}
