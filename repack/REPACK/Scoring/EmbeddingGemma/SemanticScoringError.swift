import Foundation

nonisolated enum SemanticScoringError: Error, Equatable, LocalizedError, Sendable {
    case invalidEmbeddingDimension
    case statementVectorCountMismatch
    case invalidModelSignature(String)
    case invalidEmbedding
    case unsupportedCalibration
    case emptyCalibration
    case runtimeFailure

    var errorDescription: String? {
        switch self {
        case .invalidEmbeddingDimension:
            String(localized: "EmbeddingGemma returned an invalid embedding dimension.")
        case .statementVectorCountMismatch:
            String(localized: "Semantic scoring data did not match the atomic statements.")
        case .invalidModelSignature:
            String(localized: "The EmbeddingGemma model has an unsupported tensor signature.")
        case .invalidEmbedding:
            String(localized: "EmbeddingGemma returned an invalid embedding.")
        case .unsupportedCalibration:
            String(localized: "BERTScore IDF calibration is unavailable for this model pair.")
        case .emptyCalibration:
            String(localized: "The BERTScore IDF calibration contains no statements.")
        case .runtimeFailure:
            String(localized: "EmbeddingGemma inference failed.")
        }
    }
}
