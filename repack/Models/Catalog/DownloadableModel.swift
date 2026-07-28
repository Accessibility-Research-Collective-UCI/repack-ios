import Foundation

nonisolated enum DownloadableModel:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Sendable {
    case e2b
    case e4b
    case embeddingGemma
    case embeddingGemmaTokenizer

    static let imageCaptioningModels: [DownloadableModel] = [.e2b, .e4b]
    static let embeddingModels: [DownloadableModel] = [.embeddingGemma]

    var id: Self { self }

    var displayName: String {
        switch self {
        case .e2b:
            String(localized: "Gemma 4 E2B")
        case .e4b:
            String(localized: "Gemma 4 E4B")
        case .embeddingGemma:
            String(localized: "Embedding Gemma 300M")
        case .embeddingGemmaTokenizer:
            String(localized: "Embedding Gemma tokenizer")
        }
    }

    var shortDescription: String {
        switch self {
        case .e2b:
            String(localized: "Runs on your device. Fastest captions.")
        case .e4b:
            String(
                localized:
                    "Runs on your device. Better captions, but slower. Gemma 4 E2B is also needed."
            )
        case .embeddingGemma:
            String(
                localized:
                    "Compares atomic statements by meaning. Its tokenizer is also included."
            )
        case .embeddingGemmaTokenizer:
            String(localized: "Required by Embedding Gemma 300M.")
        }
    }

    var executionLocation: ModelExecutionLocation {
        .onDevice
    }

    var descriptor: ModelDescriptor {
        switch self {
        case .e2b:
            ModelDescriptor(
                model: self,
                fileName: "gemma-4-E2B-it.litertlm",
                sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
                dependencies: [],
                source: .huggingFace(
                    HuggingFaceModelSource(
                        namespace: "litert-community",
                        name: "gemma-4-E2B-it-litert-lm",
                        revision: "9262660a1676eed6d0c477ab1a86344430854664",
                        xetHash: "ee3c29acd58e68bea04006a144cd2e40b3b34dcf5c08200a013744c518b15115"
                    )
                )
            )
        case .e4b:
            ModelDescriptor(
                model: self,
                fileName: "gemma-4-E4B-it.litertlm",
                sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
                dependencies: [.e2b],
                source: .huggingFace(
                    HuggingFaceModelSource(
                        namespace: "litert-community",
                        name: "gemma-4-E4B-it-litert-lm",
                        revision: "f7ad3343bd6ebc9607f4dc3bc4f2398bd5749bc5",
                        xetHash: "7301453651814b29d434ca0d341e365e0e28dc811cb764d836995cae25b37f31"
                    )
                )
            )
        case .embeddingGemma:
            ModelDescriptor(
                model: self,
                fileName: EmbeddingModelResources.modelFilename,
                sha256: "37115ef7bff76cd37dd86abe503ff511b1032bf85fc624a85c49c84899e92bc5",
                dependencies: [.embeddingGemmaTokenizer],
                source: .direct(
                    URL(
                        string:
                            "https://uci-repack.s3.us-west-2.amazonaws.com/embeddinggemma-300M_seq256_mixed-precision.tflite"
                    )!
                )
            )
        case .embeddingGemmaTokenizer:
            ModelDescriptor(
                model: self,
                fileName: EmbeddingModelResources.tokenizerFilename,
                sha256: "d6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7",
                dependencies: [],
                source: .direct(
                    URL(
                        string:
                            "https://uci-repack.s3.us-west-2.amazonaws.com/sentencepiece.model"
                    )!
                )
            )
        }
    }

    var fileName: String {
        descriptor.fileName
    }

    init?(modelURL: URL) {
        let identifier = modelURL.deletingPathExtension().lastPathComponent.lowercased()

        if identifier.contains("e2b") {
            self = .e2b
        } else if identifier.contains("e4b") {
            self = .e4b
        } else if modelURL.lastPathComponent
            == EmbeddingModelResources.modelFilename {
            self = .embeddingGemma
        } else if modelURL.lastPathComponent
            == EmbeddingModelResources.tokenizerFilename {
            self = .embeddingGemmaTokenizer
        } else {
            return nil
        }
    }

    static func displayName(for modelURL: URL) -> String {
        DownloadableModel(modelURL: modelURL)?.displayName
            ?? String(localized: "Imported Model")
    }

    static func shortDescription(for modelURL: URL) -> String {
        DownloadableModel(modelURL: modelURL)?.shortDescription
            ?? String(localized: "Runs on your device")
    }

    static func executionLocation(for modelURL: URL) -> ModelExecutionLocation {
        DownloadableModel(modelURL: modelURL)?.executionLocation ?? .onDevice
    }

    var dependencyOrder: [DownloadableModel] {
        var ordered: [DownloadableModel] = []
        var visited = Set<DownloadableModel>()

        func append(_ model: DownloadableModel) {
            guard visited.insert(model).inserted else { return }
            model.descriptor.dependencies.forEach(append)
            ordered.append(model)
        }

        append(self)
        return ordered
    }
}
