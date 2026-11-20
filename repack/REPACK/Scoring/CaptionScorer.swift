import Foundation

typealias ScoringProgressHandler = @MainActor @Sendable (Int, Int) -> Void

nonisolated struct PreparedCaptionScoringInput: Equatable, Sendable {
    let captionID: Int
    let statements: [String]
    let embeddings: [TokenEmbedding]?
    let embeddingDuration: Duration?

    init(
        captionID: Int,
        statements: [String],
        embeddings: [TokenEmbedding]? = nil,
        embeddingDuration: Duration? = nil
    ) {
        self.captionID = captionID
        self.statements = statements
        self.embeddings = embeddings
        self.embeddingDuration = embeddingDuration
    }
}

nonisolated protocol CaptionScorer: Sendable {
    var metric: ScoringMetric { get }

    func clearPreparationCache() async

    func prepare(
        captionID: Int,
        statements: [String]
    ) async throws -> PreparedCaptionScoringInput

    func score(
        reference: PreparedCaptionScoringInput,
        samples: [PreparedCaptionScoringInput],
        progress: @escaping ScoringProgressHandler
    ) async throws -> [ScoredAtomic]
}

extension CaptionScorer {
    func clearPreparationCache() async {}
}
