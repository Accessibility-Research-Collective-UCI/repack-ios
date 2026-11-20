#if BENCHMARKING
import Foundation

nonisolated struct BenchmarkAlgorithmProgress: Equatable, Sendable {
    let stage: BenchmarkStage?
    let fractionCompleted: Double?
}

nonisolated struct BenchmarkImageExecutionResult: Equatable, Sendable {
    let timing: BenchmarkImageTiming
    let metadata: BenchmarkImageMetadata
}

@MainActor
protocol BenchmarkAlgorithmExecuting: AnyObject {
    func process(
        image: URL,
        progress: @escaping @MainActor (BenchmarkAlgorithmProgress) -> Void
    ) async throws -> BenchmarkImageExecutionResult

    func cancel() async
}

@MainActor
protocol BenchmarkAlgorithmExecutorBuilding: AnyObject {
    func resolve(_ request: BenchmarkRunRequest) -> ResolvedBenchmarkRun
    func makeExecutor(for run: ResolvedBenchmarkRun) async throws
        -> any BenchmarkAlgorithmExecuting
}

@MainActor
final class DefaultBenchmarkAlgorithmExecutorFactory: BenchmarkAlgorithmExecutorBuilding {
    private let engineFactory: any EngineFactory
    private let devicePolicy: DevicePolicy

    init(
        engineFactory: any EngineFactory = LiteRTEngineFactory.shared,
        devicePolicy: DevicePolicy = .current
    ) {
        self.engineFactory = engineFactory
        self.devicePolicy = devicePolicy
    }

    func resolve(_ request: BenchmarkRunRequest) -> ResolvedBenchmarkRun {
        let resources: EmbeddingModelResources?
        if case .repack(let settings) = request.algorithmConfiguration,
           settings.scoringMetric == .semanticSimilarity {
            resources = EmbeddingModelResources.available()
        } else {
            resources = nil
        }
        return ResolvedBenchmarkRun(
            request: request,
            visionSettings: engineFactory.visionSettings,
            textSettings: engineFactory.textSettings,
            embeddingResources: resources
        )
    }

    func makeExecutor(for run: ResolvedBenchmarkRun) async throws
        -> any BenchmarkAlgorithmExecuting {
        let request = run.request
        return switch request.algorithmConfiguration {
        case .repack(let configuration):
            try await REPACKBenchmarkExecutor(
                visionModelURL: request.visionModel.url,
                textModelURL: request.textModel.url,
                prompt: CaptionPrompt.custom(request.prompt.text),
                configuration: configuration,
                embeddingResources: run.embeddingResources,
                calibration: run.calibration,
                engineFactory: engineFactory,
                devicePolicy: devicePolicy
            )
        case .capmas:
            try await CapMASBenchmarkExecutor(
                visionModelURL: request.visionModel.url,
                textModelURL: request.textModel.url,
                prompt: request.prompt.text,
                engineFactory: engineFactory
            )
        case .taco(let sampleCount):
            try await TACOBenchmarkExecutor(
                visionModelURL: request.visionModel.url,
                textModelURL: request.textModel.url,
                prompt: request.prompt.text,
                reformulationCount: sampleCount,
                engineFactory: engineFactory
            )
        }
    }
}

extension Duration {
    nonisolated var benchmarkSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
