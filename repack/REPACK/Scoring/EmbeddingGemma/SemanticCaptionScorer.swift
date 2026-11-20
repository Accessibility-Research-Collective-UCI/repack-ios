/// Scores each distinct ordered statement pair once, then preserves original occurrences.
nonisolated struct SemanticCaptionScorer: CaptionScorer {
    static let implementation = "bertscore-f1-idf-layer16-v1"

    let metric = ScoringMetric.semanticSimilarity
    private let embeddingProvider: (any TextEmbeddingProviding)?

    init(embeddingProvider: (any TextEmbeddingProviding)? = nil) {
        self.embeddingProvider = embeddingProvider
    }

    func clearPreparationCache() async {
        await embeddingProvider?.clearStatementCache()
    }

    func prepare(
        captionID: Int,
        statements: [String]
    ) async throws -> PreparedCaptionScoringInput {
        guard let embeddingProvider else {
            throw PipelineError.missingEmbeddingModel
        }
        return PreparedCaptionScoringInput(
            captionID: captionID,
            statements: statements,
            embeddings: try await embeddingProvider.embeddings(for: statements)
        )
    }

    @concurrent
    func score(
        reference: PreparedCaptionScoringInput,
        samples: [PreparedCaptionScoringInput],
        progress: @escaping ScoringProgressHandler
    ) async throws -> [ScoredAtomic] {
        guard !reference.statements.isEmpty else { return [] }
        guard let referenceVectors = reference.embeddings,
              reference.statements.count == referenceVectors.count else {
            throw SemanticScoringError.statementVectorCountMismatch
        }
        let sampleVectors = try samples.map { sample in
            guard let vectors = sample.embeddings,
                  sample.statements.count == vectors.count else {
                throw SemanticScoringError.statementVectorCountMismatch
            }
            return vectors
        }

        struct Pair: Hashable {
            let reference: String
            let sample: String
        }
        var pairScores: [Pair: Float] = [:]

        var results: [ScoredAtomic] = []
        results.reserveCapacity(reference.statements.count)

        for referenceIndex in reference.statements.indices {
            try Task.checkCancellation()
            await progress(referenceIndex, reference.statements.count)
            var matches: [AtomicMatch] = []
            matches.reserveCapacity(samples.count)

            for (sampleOffset, sample) in samples.enumerated() {
                var bestGeneratedIndex: Int?
                var bestScore = -Float.infinity

                for generatedIndex in sample.statements.indices {
                    try Task.checkCancellation()
                    let pair = Pair(reference: reference.statements[referenceIndex],
                                    sample: sample.statements[generatedIndex])
                    let score: Float
                    if let cached = pairScores[pair] {
                        score = cached
                    } else {
                        score = try BERTScore.f1(referenceVectors[referenceIndex],
                                                 sampleVectors[sampleOffset][generatedIndex])
                        pairScores[pair] = score
                    }
                    if bestGeneratedIndex == nil || score > bestScore {
                        bestGeneratedIndex = generatedIndex
                        bestScore = score
                    }
                }

                let statementIndex = bestGeneratedIndex
                matches.append(
                    AtomicMatch(
                        sampleIndex: sampleOffset + 1,
                        statement: statementIndex.map { sample.statements[$0] },
                        score: bestGeneratedIndex == nil
                            ? 0
                            : min(max(Double(bestScore), 0), 1)
                    )
                )
            }

            let average = matches.isEmpty
                ? 0
                : matches.reduce(0) { $0 + $1.score } / Double(matches.count)
            results.append(
                ScoredAtomic(
                    index: referenceIndex,
                    statement: reference.statements[referenceIndex],
                    matches: matches,
                    averageScore: average
                )
            )
            await progress(results.count, reference.statements.count)
        }

        return results
    }
}
