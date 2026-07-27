import Foundation

@MainActor
protocol CaptionScorer: AnyObject {
    func score(
        referenceAtomics: [String],
        sampleAtomics: [[String]],
        progress: (Int, Int) -> Void
    ) async throws -> [ScoredAtomic]
}

@MainActor
final class BLEUCaptionScorer: CaptionScorer {
    func score(
        referenceAtomics: [String],
        sampleAtomics: [[String]],
        progress: (Int, Int) -> Void
    ) async throws -> [ScoredAtomic] {
        var results: [ScoredAtomic] = []
        results.reserveCapacity(referenceAtomics.count)

        for (referenceIndex, referenceAtomic) in referenceAtomics.enumerated() {
            try Task.checkCancellation()
            progress(referenceIndex, referenceAtomics.count)

            var matches: [AtomicMatch] = []
            matches.reserveCapacity(sampleAtomics.count)

            for (sampleOffset, atomics) in sampleAtomics.enumerated() {
                var bestStatement: String?
                var bestScore = 0.0

                for atomic in atomics {
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
            progress(results.count, referenceAtomics.count)
        }

        return results
    }
}
