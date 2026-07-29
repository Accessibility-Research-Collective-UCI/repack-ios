#if BENCHMARKING
import Foundation
import Testing
@testable import repack

@Suite("Benchmarking")
@MainActor
struct BenchmarkingTests {
    @Test("REPACK always uses the metric default threshold")
    func metricDefaultThresholds() {
        var configuration = REPACKBenchmarkConfiguration.default
        #expect(
            configuration.similarityThreshold
                == ScoringMetric.bleu.threshold.defaultValue
        )

        configuration.scoringMetric = .semanticSimilarity
        #expect(
            configuration.similarityThreshold
                == ScoringMetric.semanticSimilarity.threshold.defaultValue
        )
    }

    @Test("Engine choices remain selectable before model discovery")
    func stableEngineChoices() {
        let model = BenchmarkViewModel(
            localModels: [],
            devicePolicy: DevicePolicy(modelIdentifier: "iPhone18,1")
        )

        model.visionModel = .gemma4E4B
        model.textModel = .gemma4E2B
        #expect(model.modelStatus(.gemma4E4B) == "Not installed")
        #expect(!model.canStart)

        model.updateLocalModels([
            LocalModel(
                url: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
                isBundled: false
            ),
            LocalModel(
                url: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
                isBundled: false
            )
        ])

        #expect(model.modelStatus(.gemma4E4B) == "Installed")
        #expect(model.canStart)
    }

    @Test("Runner sorts images and excludes cooldown from timing aggregates")
    func deterministicOrderingAndActiveTiming() async {
        let dateProvider = FakeDateProvider()
        let executor = FakeBenchmarkExecutor(durations: [
            "a.jpg": 2,
            "b.jpg": 3
        ])
        let submitter = FakeBenchmarkSubmitter()
        let runner = BenchmarkRunner(
            executorFactory: FakeExecutorFactory(executor: executor),
            imageProvider: FakeImageProvider(files: ["b.jpg", "a.jpg"]),
            sleeper: AdvancingSleeper(dateProvider: dateProvider),
            dateProvider: dateProvider,
            deviceInformationProvider: FakeDeviceInformationProvider(),
            submitter: submitter,
            idleTimerManager: FakeIdleTimerManager()
        )

        let output = await runner.run(request: request()) { _ in }

        #expect(executor.processedFiles == ["a.jpg", "b.jpg"])
        #expect(output.results.totalTime == 5)
        #expect(output.results.averageTime == 2.5)
        #expect(output.runEndTime.timeIntervalSince(output.runStartTime) == 15)
        #expect(output.status == .completed)
        #expect(submitter.outputs == [output])
    }

    @Test("Runner stops on the first failed image and keeps partial output")
    func stopOnFirstFailure() async {
        let executor = FakeBenchmarkExecutor(
            durations: ["a.jpg": 2],
            failingFile: "b.jpg"
        )
        let runner = BenchmarkRunner(
            executorFactory: FakeExecutorFactory(executor: executor),
            imageProvider: FakeImageProvider(
                files: ["c.jpg", "b.jpg", "a.jpg"]
            ),
            sleeper: BenchmarkTaskSleeper(),
            dateProvider: FakeDateProvider(),
            deviceInformationProvider: FakeDeviceInformationProvider(),
            submitter: FakeBenchmarkSubmitter(),
            idleTimerManager: FakeIdleTimerManager()
        )

        let output = await runner.run(
            request: request(cooldownSeconds: 0)
        ) { _ in }

        #expect(executor.processedFiles == ["a.jpg", "b.jpg"])
        #expect(output.completedImageCount == 1)
        #expect(output.results.totalTime == 2)
        #expect(output.status == .failed)
        #expect(output.failure?.kind == .imageFailure)
        #expect(output.failure?.file == "b.jpg")
    }

    @Test("Output uses ISO dates and records engine policy")
    func serialization() throws {
        let request = request()
        let output = BenchmarkOutput(
            runStartTime: Date(timeIntervalSince1970: 0),
            runEndTime: Date(timeIntervalSince1970: 1),
            iPhoneModel: "iPhone18,1",
            iPhoneIdentifier: "test-device",
            appVersion: "1.0",
            buildVersion: "7",
            osVersion: "26.0",
            algorithm: .repack,
            imageCount: 25,
            completedImageCount: 0,
            benchmarkSettings: request.exportedSettings,
            results: BenchmarkResults(timing: []),
            metadata: [],
            status: .completed,
            failure: nil
        )

        let json = output.formattedJSON()
        #expect(json.contains("\"runStartTime\" : \"1970-01-01T00:00:00Z\""))
        #expect(json.contains("\"visionBackend\" : \"gpu\""))
        #expect(json.contains("\"mtpEnabled\" : true"))
        #expect(json.contains("\"similarityThreshold\" : 0.5"))
        #expect(
            output.exportFilename
                == "benchmark-repack_test-device_gemma-4-e2b_gemma-4-e2b_describe_samples5.json"
        )
    }

    @Test("Remaining time includes only cooldowns between remaining images")
    func estimatedTimeRemaining() {
        let estimate = BenchmarkViewModel.estimatedTimeRemaining(
            averageDuration: .seconds(10),
            completedImageCount: 14,
            totalImageCount: 25,
            cooldownSeconds: 15
        )

        #expect(estimate == .seconds(260))
    }

    private func request(cooldownSeconds: Int = 15) -> BenchmarkRunRequest {
        let vision = ResolvedBenchmarkModel(
            choice: .gemma4E2B,
            url: URL(fileURLWithPath: "/tmp/vision.litertlm")
        )
        let text = ResolvedBenchmarkModel(
            choice: .gemma4E2B,
            url: URL(fileURLWithPath: "/tmp/text.litertlm")
        )
        return BenchmarkRunRequest(
            algorithm: .repack,
            visionModel: vision,
            textModel: text,
            algorithmConfiguration: .repack(.default),
            prompt: BenchmarkPromptSettings(
                type: .describe,
                text: Prompts.describePrompt
            ),
            cooldownSeconds: cooldownSeconds
        )
    }
}

@MainActor
private final class FakeExecutorFactory: BenchmarkAlgorithmExecutorBuilding {
    let executor: FakeBenchmarkExecutor

    init(executor: FakeBenchmarkExecutor) {
        self.executor = executor
    }

    func makeExecutor(for _: BenchmarkRunRequest) async throws
        -> any BenchmarkAlgorithmExecuting {
        executor
    }
}

@MainActor
private final class FakeBenchmarkExecutor: BenchmarkAlgorithmExecuting {
    enum Failure: Error {
        case expected
    }

    let algorithm = BenchmarkAlgorithm.repack
    let stages = BenchmarkAlgorithm.repack.stages
    let durations: [String: Double]
    let failingFile: String?
    private(set) var processedFiles: [String] = []

    init(durations: [String: Double], failingFile: String? = nil) {
        self.durations = durations
        self.failingFile = failingFile
    }

    func process(
        image: URL,
        progress: @escaping @MainActor (BenchmarkAlgorithmProgress) -> Void
    ) async throws -> BenchmarkImageExecutionResult {
        let file = image.lastPathComponent
        processedFiles.append(file)
        if file == failingFile {
            throw Failure.expected
        }
        progress(
            BenchmarkAlgorithmProgress(
                stage: stages.first,
                fractionCompleted: 1
            )
        )
        let duration = durations[file] ?? 1
        return BenchmarkImageExecutionResult(
            timing: BenchmarkImageTiming(
                file: file,
                totalTime: duration,
                stages: ["sampling": duration]
            ),
            metadata: BenchmarkImageMetadata(
                file: file,
                details: .repack(
                    REPACKBenchmarkMetadata(
                        captions: [],
                        scoredAtomics: [],
                        retainedAtomics: [],
                        finalCaption: ""
                    )
                )
            )
        )
    }

    func cancel() async {}
}

@MainActor
private struct FakeImageProvider: BenchmarkImageProviding {
    let files: [String]
    var expectedImageCount: Int { files.count }

    func images() throws -> [URL] {
        files.map { URL(fileURLWithPath: "/tmp/\($0)") }
    }
}

@MainActor
private final class FakeDateProvider: BenchmarkDateProviding {
    var current = Date(timeIntervalSince1970: 1_000)
    var now: Date { current }
}

@MainActor
private struct AdvancingSleeper: BenchmarkSleeping {
    let dateProvider: FakeDateProvider

    func sleep(for duration: Duration) async throws {
        dateProvider.current.addTimeInterval(duration.seconds)
    }
}

@MainActor
private struct FakeDeviceInformationProvider:
    BenchmarkDeviceInformationProviding {
    func information() -> BenchmarkDeviceInformation {
        BenchmarkDeviceInformation(
            hardwareModel: "iPhone18,1",
            identifier: "test-device",
            appVersion: "1",
            buildVersion: "1",
            osVersion: "26"
        )
    }
}

@MainActor
private final class FakeBenchmarkSubmitter: BenchmarkResultSubmitting {
    private(set) var outputs: [BenchmarkOutput] = []

    func submit(_ output: BenchmarkOutput) async throws {
        outputs.append(output)
    }
}

@MainActor
private final class FakeIdleTimerManager: IdleTimerManaging {
    func setPreventingIdleSleep(_: Bool, owner _: UUID) {}
}

private extension Duration {
    nonisolated var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
