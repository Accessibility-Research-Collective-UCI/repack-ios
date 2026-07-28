import Foundation

/// Resolves the model and tokenizer as one installable embedding resource.
nonisolated struct EmbeddingModelResources: Equatable, Sendable {
    static let modelFilename =
        "embeddinggemma-300M_seq256_mixed-precision.tflite"
    static let tokenizerFilename = "sentencepiece.model"
    static let displayName = String(localized: "Embedding Gemma 300M")

    let modelURL: URL
    let tokenizerURL: URL

    static func bundled(in bundle: Bundle = .main) -> EmbeddingModelResources? {
        guard let modelURL = bundle.url(
            forResource: modelFilename,
            withExtension: nil,
            subdirectory: "DevelopmentModels"
        ),
        let tokenizerURL = bundle.url(
            forResource: tokenizerFilename,
            withExtension: nil,
            subdirectory: "DevelopmentModels"
        ) else {
            return nil
        }

        return EmbeddingModelResources(
            modelURL: modelURL,
            tokenizerURL: tokenizerURL
        )
    }

    static func available(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> EmbeddingModelResources? {
        #if DEBUG
            if let bundled = bundled(in: bundle) {
                return bundled
            }
        #endif

        guard let modelsDirectory = try? ModelLibrary.modelsDirectory(
            fileManager: fileManager
        ) else {
            return nil
        }
        let modelURL = modelsDirectory.appending(path: modelFilename)
        let tokenizerURL = modelsDirectory.appending(path: tokenizerFilename)
        guard fileManager.fileExists(atPath: modelURL.path),
              fileManager.fileExists(atPath: tokenizerURL.path) else {
            return nil
        }
        return EmbeddingModelResources(
            modelURL: modelURL,
            tokenizerURL: tokenizerURL
        )
    }
}
