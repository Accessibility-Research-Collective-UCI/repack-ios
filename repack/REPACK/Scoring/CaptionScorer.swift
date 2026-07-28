import Foundation

typealias ScoringProgressHandler = @MainActor @Sendable (Int, Int) -> Void

nonisolated struct PreparedCaptionScoringInput: Equatable, Sendable {
    let captionID: Int
    let statements: [String]
    let vectors: [[Float]]?

    init(
        captionID: Int,
        statements: [String],
        vectors: [[Float]]? = nil
    ) {
        self.captionID = captionID
        self.statements = statements
        self.vectors = vectors
    }
}

nonisolated protocol CaptionScorer: Sendable {
    var metric: ScoringMetric { get }

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
