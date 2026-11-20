/// Produces normalized token vectors with calibration weights.
nonisolated protocol TextEmbeddingProviding: Sendable {
    func embeddings(for statements: [String]) async throws -> [TokenEmbedding]
    func clearStatementCache() async
}

extension TextEmbeddingProviding {
    func clearStatementCache() async {}
}
