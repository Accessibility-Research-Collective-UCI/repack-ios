import Foundation
import LiteRTLM

@MainActor
final class ModelInit {
    private(set) var engine: Engine?
    private(set) var modelURL: URL?

    func loadEngine(for selectedModelURL: URL) async throws -> Engine {
        let availableMemory = os_proc_available_memory()
        print("Available memory for app: \(availableMemory) bytes")

        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = false
        ExperimentalFlags.visualTokenBudget = 1_120

        if let engine, ModelManager.sameFile(modelURL, selectedModelURL) {
            return engine
        }

        let config = try EngineConfig(
            modelPath: selectedModelURL.path,
            backend: .gpu,
            visionBackend: .cpu(),
            maxNumTokens: 2048,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: config)
        try await engine.initialize()

        self.engine = engine
        modelURL = selectedModelURL
        return engine
    }

    func loadSampler(for selectedModelURL: URL) async throws -> Sampler {
        Sampler(engine: try await loadEngine(for: selectedModelURL))
    }

    func hasEngine(for selectedModelURL: URL) -> Bool {
        engine != nil && ModelManager.sameFile(modelURL, selectedModelURL)
    }

    func reset() {
        engine = nil
        modelURL = nil
    }
}
