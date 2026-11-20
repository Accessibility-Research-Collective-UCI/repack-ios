import Foundation

/// Valid tokens only, including special tokens. Padding never participates in matching.
nonisolated struct TokenEmbedding: Equatable, Sendable {
    let tokenIDs: [Int]
    let vectors: [Float]
    let dimension: Int
    let weights: [Float]

    init(tokenIDs: [Int], vectors: [Float], dimension: Int, weights: [Float]) throws {
        guard dimension > 0, vectors.count == tokenIDs.count * dimension,
              weights.count == tokenIDs.count else {
            throw SemanticScoringError.invalidEmbeddingDimension
        }
        guard vectors.allSatisfy(\.isFinite),
              weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SemanticScoringError.invalidEmbedding
        }
        self.tokenIDs = tokenIDs
        self.vectors = vectors
        self.dimension = dimension
        self.weights = weights
    }
}
