import Foundation

/// Resolves the token model, tokenizer, and calibration corpora as one installable embedding resource.
nonisolated struct EmbeddingModelResources: Equatable, Sendable {
    static let modelFilename =
        "embeddinggemma-300m-bertscore-layer16-seq256-f32.tflite"
    static let tokenizerFilename = "sentencepiece.model"
    static let displayName = String(localized: "Embedding Gemma 300M")

    let modelURL: URL
    let tokenizerURL: URL

    func calibrationURL(for calibration: IDFCalibration) -> URL {
        modelURL.deletingLastPathComponent().appending(path: calibration.filename)
    }

    private var hasCalibrations: Bool {
        IDFCalibration.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: calibrationURL(for: $0).path)
        }
    }

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

        let resources = EmbeddingModelResources(
            modelURL: modelURL,
            tokenizerURL: tokenizerURL
        )
        return resources.hasCalibrations ? resources : nil
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
        let resources = EmbeddingModelResources(
            modelURL: modelURL,
            tokenizerURL: tokenizerURL
        )
        return resources.hasCalibrations ? resources : nil
    }
}
