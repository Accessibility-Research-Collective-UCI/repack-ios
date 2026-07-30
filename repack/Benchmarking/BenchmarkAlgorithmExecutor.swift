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
    var algorithm: BenchmarkAlgorithm { get }
    var stages: [BenchmarkStage] { get }

    func process(
        image: URL,
        progress: @escaping @MainActor (BenchmarkAlgorithmProgress) -> Void
    ) async throws -> BenchmarkImageExecutionResult

    func cancel() async
}

@MainActor
protocol BenchmarkAlgorithmExecutorBuilding: AnyObject {
    func makeExecutor(for request: BenchmarkRunRequest) async throws
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

    func makeExecutor(for request: BenchmarkRunRequest) async throws
        -> any BenchmarkAlgorithmExecuting {
        switch request.algorithmConfiguration {
        case .repack(let configuration):
            try await REPACKBenchmarkExecutor(
                visionModelURL: request.visionModel.url,
                textModelURL: request.textModel.url,
                prompt: CaptionPrompt.custom(request.prompt.text),
                configuration: configuration,
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
        }
    }
}

extension Duration {
    nonisolated var benchmarkSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
