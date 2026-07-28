/// Prepares Embedding Gemma vectors and scores their cosine similarity.
nonisolated struct SemanticCaptionScorer: CaptionScorer {
    let metric = ScoringMetric.semanticSimilarity
    private let embeddingProvider: (any TextEmbeddingProviding)?

    init(embeddingProvider: (any TextEmbeddingProviding)? = nil) {
        self.embeddingProvider = embeddingProvider
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
            vectors: try await embeddingProvider.embeddings(for: statements)
        )
    }

    @concurrent
    func score(
        reference: PreparedCaptionScoringInput,
        samples: [PreparedCaptionScoringInput],
        progress: @escaping ScoringProgressHandler
    ) async throws -> [ScoredAtomic] {
        guard !reference.statements.isEmpty else { return [] }
        guard let referenceVectors = reference.vectors,
              reference.statements.count == referenceVectors.count else {
            throw SemanticScoringError.statementVectorCountMismatch
        }
        let sampleVectors = try samples.map { sample in
            guard let vectors = sample.vectors,
                  sample.statements.count == vectors.count else {
                throw SemanticScoringError.statementVectorCountMismatch
            }
            return vectors
        }

        let similarityMatrix = try SemanticSimilarityMatrix(
            reference: referenceVectors,
            samples: sampleVectors
        )

        var results: [ScoredAtomic] = []
        results.reserveCapacity(reference.statements.count)

        for referenceIndex in reference.statements.indices {
            try Task.checkCancellation()
            await progress(referenceIndex, reference.statements.count)
            var matches: [AtomicMatch] = []
            matches.reserveCapacity(samples.count)

            for (sampleOffset, sample) in samples.enumerated() {
                let range = similarityMatrix.sampleRanges[sampleOffset]
                var bestGeneratedIndex: Int?
                var bestScore = -Float.infinity

                for generatedIndex in range {
                    let score = similarityMatrix[
                        generatedIndex,
                        referenceIndex
                    ]
                    if bestGeneratedIndex == nil || score > bestScore {
                        bestGeneratedIndex = generatedIndex
                        bestScore = score
                    }
                }

                let statementIndex = bestGeneratedIndex.map { $0 - range.lowerBound }
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
