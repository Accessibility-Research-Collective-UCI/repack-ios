import Foundation

nonisolated struct MeasuredEmbeddings: Sendable {
    let embeddings: [TokenEmbedding]
    let duration: Duration
}

/// Produces normalized token vectors with calibration weights.
nonisolated protocol TextEmbeddingProviding: Sendable {
    func embeddings(for statements: [String]) async throws -> MeasuredEmbeddings
    func clearStatementCache() async
}

extension TextEmbeddingProviding {
    func clearStatementCache() async {}
}
