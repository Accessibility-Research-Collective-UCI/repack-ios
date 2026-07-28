import Foundation

/// Produces normalized vectors for semantic similarity scoring.
nonisolated protocol TextEmbeddingProviding: Sendable {
    func embeddings(for statements: [String]) async throws -> [[Float]]
}
