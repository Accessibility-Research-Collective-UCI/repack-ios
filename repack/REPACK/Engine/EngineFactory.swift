@preconcurrency import LiteRTLM
import Foundation

@MainActor
protocol EngineFactory: AnyObject {
    func validateModel(at modelURL: URL) throws
    func makeVisionEngine(modelURL: URL) async throws -> any InferenceEngine
    func makeTextEngine(modelURL: URL) async throws -> any InferenceEngine
}

@MainActor
final class LiteRTEngineFactory: EngineFactory {
    static let shared = LiteRTEngineFactory()

    private init() {}

    func validateModel(at modelURL: URL) throws {
        guard Capabilities(modelPath: modelURL.path) != nil else {
            throw PipelineError.invalidModel
        }
    }

    func makeVisionEngine(modelURL: URL) async throws -> any InferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = false
        ExperimentalFlags.visualTokenBudget = 1_120
        return try await makeEngine(modelURL: modelURL, includesVision: true)
    }

    func makeTextEngine(modelURL: URL) async throws -> any InferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = true
        return try await makeEngine(modelURL: modelURL, includesVision: false)
    }

    private func makeEngine(modelURL: URL, includesVision: Bool) async throws -> InferenceEngine {
        let modelName = modelURL.deletingPathExtension().lastPathComponent
        MemoryDiagnostics.log("Before creating \(includesVision ? "vision" : "text") engine: \(modelName)")

        let configuration = try EngineConfig(
            modelPath: modelURL.path,
            backend: .gpu,
            visionBackend: includesVision ? .gpu : nil,
            maxNumTokens: 3072,
            cacheDir: FileManager.default.temporaryDirectory.path
        )
        let engine = Engine(engineConfig: configuration)
        try await engine.initialize()
        MemoryDiagnostics.log("After creating \(includesVision ? "vision" : "text") engine: \(modelName)")
        return LiteRTInferenceEngine(engine: engine)
    }
}
