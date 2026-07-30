#if BENCHMARKING
import Foundation

nonisolated enum BenchmarkRunnerEvent: Equatable, Sendable {
    case imageStarted(index: Int, total: Int, file: String, at: Date)
    case algorithmProgress(BenchmarkAlgorithmProgress)
    case imageCompleted(index: Int, total: Int, timing: BenchmarkImageTiming)
    case cooldown(secondsRemaining: Int)
}

@MainActor
final class BenchmarkRunner {
    typealias EventHandler = @MainActor (BenchmarkRunnerEvent) -> Void

    private let executorFactory: any BenchmarkAlgorithmExecutorBuilding
    private let imageProvider: any BenchmarkImageProviding
    private let sleeper: any BenchmarkSleeping
    private let dateProvider: any BenchmarkDateProviding
    private let deviceInformationProvider: any BenchmarkDeviceInformationProviding

    private var executor: (any BenchmarkAlgorithmExecuting)?
    private var interruption: BenchmarkFailure?

    init(
        executorFactory: any BenchmarkAlgorithmExecutorBuilding =
            DefaultBenchmarkAlgorithmExecutorFactory(),
        imageProvider: any BenchmarkImageProviding =
            BundleBenchmarkImageProvider(),
        sleeper: any BenchmarkSleeping = BenchmarkTaskSleeper(),
        dateProvider: any BenchmarkDateProviding = SystemBenchmarkDateProvider(),
        deviceInformationProvider: any BenchmarkDeviceInformationProviding =
            SystemBenchmarkDeviceInformationProvider()
    ) {
        self.executorFactory = executorFactory
        self.imageProvider = imageProvider
        self.sleeper = sleeper
        self.dateProvider = dateProvider
        self.deviceInformationProvider = deviceInformationProvider
    }

    func run(
        request: BenchmarkRunRequest,
        event: @escaping EventHandler
    ) async -> BenchmarkOutput {
        let start = dateProvider.now
        let deviceInformation = deviceInformationProvider.information()
        var timings: [BenchmarkImageTiming] = []
        var metadata: [BenchmarkImageMetadata] = []
        var status = BenchmarkCompletionState.completed
        var failure: BenchmarkFailure?
        var currentFile: String?

        interruption = nil
        defer { executor = nil }

        do {
            let images = try imageProvider.images().sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
            let preparedExecutor = try await executorFactory.makeExecutor(for: request)
            executor = preparedExecutor

            for (offset, image) in images.enumerated() {
                try Task.checkCancellation()
                currentFile = image.lastPathComponent
                event(
                    .imageStarted(
                        index: offset,
                        total: images.count,
                        file: image.lastPathComponent,
                        at: dateProvider.now
                    )
                )
                let result = try await preparedExecutor.process(image: image) {
                    event(.algorithmProgress($0))
                }
                timings.append(result.timing)
                metadata.append(result.metadata)
                event(
                    .imageCompleted(
                        index: offset + 1,
                        total: images.count,
                        timing: result.timing
                    )
                )

                if offset < images.count - 1 {
                    try await cooldown(
                        seconds: request.cooldownSeconds,
                        event: event
                    )
                }
            }
        } catch is CancellationError {
            status = .interrupted
            failure = interruption ?? BenchmarkFailure(
                kind: .cancelled,
                message: String(localized: "Benchmark cancelled."),
                file: currentFile
            )
        } catch let benchmarkFailure as BenchmarkFailure {
            status = benchmarkFailure.kind == .backgrounded ? .interrupted : .failed
            failure = benchmarkFailure
        } catch {
            status = .failed
            failure = BenchmarkFailure(
                kind: currentFile == nil ? .setupFailure : .imageFailure,
                message: error.localizedDescription,
                file: currentFile
            )
        }

        let output = BenchmarkOutput(
            runStartTime: start,
            runEndTime: dateProvider.now,
            iPhoneModel: deviceInformation.hardwareModel,
            iPhoneIdentifier: deviceInformation.identifier,
            appVersion: deviceInformation.appVersion,
            buildVersion: deviceInformation.buildVersion,
            osVersion: deviceInformation.osVersion,
            algorithm: request.algorithm,
            imageCount: imageProvider.expectedImageCount,
            completedImageCount: timings.count,
            benchmarkSettings: request.exportedSettings,
            results: BenchmarkResults(timing: timings),
            metadata: metadata,
            status: status,
            failure: failure
        )

        return output
    }

    func setInterruption(_ failure: BenchmarkFailure) {
        interruption = failure
    }

    func cancelCurrentExecution() async {
        await executor?.cancel()
    }

    private func cooldown(
        seconds cooldownSeconds: Int,
        event: EventHandler
    ) async throws {
        guard cooldownSeconds > 0 else { return }
        for seconds in stride(from: cooldownSeconds, through: 1, by: -1) {
            try Task.checkCancellation()
            event(.cooldown(secondsRemaining: seconds))
            try await sleeper.sleep(for: .seconds(1))
        }
    }
}
#endif
