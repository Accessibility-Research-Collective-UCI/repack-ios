import Foundation

nonisolated enum PipelineError: Error, Equatable, LocalizedError, Sendable {
    case invalidSampleCount(Int)
    case emptyPrompt
    case invalidThreshold(Double)
    case invalidModel
    case e4BUnavailableOnDevice
    case missingE2BProcessingModel
    case missingVisionEngine
    case missingTextEngine
    case missingEmbeddingModel
    case noCachedResult
    case emptyModelResponse

    var errorDescription: String? {
        switch self {
        case .invalidSampleCount(let count):
            String(localized: "Sample count must be between 1 and 10. Received \(count).")
        case .emptyPrompt:
            String(localized: "Enter a prompt before captioning the image.")
        case .invalidThreshold:
            String(localized: "The threshold must be between 0 and 1.")
        case .invalidModel:
            String(localized: "The selected file is not a compatible LiteRT-LM model.")
        case .e4BUnavailableOnDevice:
            String(localized: "Gemma 4 E4B is not available on this iPhone.")
        case .missingE2BProcessingModel:
            String(localized: "Gemma 4 E2B is required to process captions sampled with E4B.")
        case .missingVisionEngine:
            String(localized: "The vision model is not ready.")
        case .missingTextEngine:
            String(localized: "The text model is not ready.")
        case .missingEmbeddingModel:
            String(
                localized:
                    "Semantic Similarity requires the EmbeddingGemma model and tokenizer."
            )
        case .noCachedResult:
            String(localized: "Generate a caption before changing its threshold.")
        case .emptyModelResponse:
            String(localized: "The model returned an empty response.")
        }
    }
}
