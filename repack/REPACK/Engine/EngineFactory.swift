@preconcurrency import LiteRTLM
import Foundation

nonisolated struct InferenceEngineSettings: Equatable, Sendable {
    let backend: Backend
    let visionBackend: Backend?
    let mtpEnabled: Bool
    let maxNumTokens = 3072

    static let vision = Self(backend: .gpu, visionBackend: .gpu, mtpEnabled: true)
    static let text = Self(backend: .gpu, visionBackend: nil, mtpEnabled: true)

    func configuration(modelURL: URL) throws -> EngineConfig {
        try EngineConfig(
            modelPath: modelURL.path,
            backend: backend,
            visionBackend: visionBackend,
            maxNumTokens: maxNumTokens,
            cacheDir: FileManager.default.temporaryDirectory.path,
            speculativeDecodingConfig: .init(mode: mtpEnabled ? .on : .off)
        )
    }
}

@MainActor
protocol EngineFactory: AnyObject {
    var visionSettings: InferenceEngineSettings { get }
    var textSettings: InferenceEngineSettings { get }
    func validateModel(at modelURL: URL) throws
    func makeVisionEngine(modelURL: URL) async throws -> any InferenceEngine
    func makeTextEngine(modelURL: URL) async throws -> any InferenceEngine
}

@MainActor
final class LiteRTEngineFactory: EngineFactory {
    static let shared = LiteRTEngineFactory()

    let visionSettings = InferenceEngineSettings.vision
    let textSettings = InferenceEngineSettings.text

    private init() {}

    func validateModel(at modelURL: URL) throws {
        guard ModelInfo(modelPath: modelURL.path) != nil else {
            throw PipelineError.invalidModel
        }
    }

    func makeVisionEngine(modelURL: URL) async throws -> any InferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        return try await makeEngine(modelURL: modelURL, settings: visionSettings)
    }

    func makeTextEngine(modelURL: URL) async throws -> any InferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        return try await makeEngine(modelURL: modelURL, settings: textSettings)
    }

    private func makeEngine(modelURL: URL, settings: InferenceEngineSettings) async throws -> InferenceEngine {
        let includesVision = settings.visionBackend != nil
        let modelName = modelURL.deletingPathExtension().lastPathComponent
        MemoryDiagnostics.log("Before creating \(includesVision ? "vision" : "text") engine: \(modelName)")

        let configuration = try settings.configuration(modelURL: modelURL)
        let engine = Engine(engineConfig: configuration)
        try await engine.initialize()
        MemoryDiagnostics.log("After creating \(includesVision ? "vision" : "text") engine: \(modelName)")
        return LiteRTInferenceEngine(engine: engine)
    }
}
