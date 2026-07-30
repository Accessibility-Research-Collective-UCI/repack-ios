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

        model.algorithm = .capmas
        model.scoringMetric = .semanticSimilarity
        #expect(
            !model.preflightMessages.contains {
                $0.localizedStandardContains("Embedding Gemma")
            }
        )
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

    @Test("CapMAS retries decomposition and runs verification sequentially")
    func capmasExecution() async throws {
        let vision = CapMASFakeInferenceEngine(
            captionResponses: ["A red can.", "ignored", "ignored"]
        )
        let text = CapMASFakeInferenceEngine(
            textResponses: [
                "",
                "1. There is a can.\n2. The can is red.",
                "###A can.###"
            ]
        )
        let executor = try await CapMASBenchmarkExecutor(
            visionModelURL: URL(fileURLWithPath: "/tmp/vision.litertlm"),
            textModelURL: URL(fileURLWithPath: "/tmp/text.litertlm"),
            prompt: "Describe the product.",
            engineFactory: CapMASFakeEngineFactory(
                visionEngine: vision,
                textEngine: text
            )
        )
        var progress: [BenchmarkAlgorithmProgress] = []

        let result = try await executor.process(
            image: URL(fileURLWithPath: "/tmp/example.jpg")
        ) {
            progress.append($0)
        }

        #expect(vision.captionPrompts == [
            "Describe the product.",
            "True or False? There is a can.",
            "True or False? The can is red."
        ])
        #expect(text.textPrompts.count == 3)
        #expect(result.timing.stages.keys.sorted() == [
            "captioning", "correction", "decomposition", "verification"
        ])
        let verificationProgress = progress.compactMap {
            $0.stage?.id == "verification" ? $0.fractionCompleted : nil
        }
        #expect(verificationProgress == verificationProgress.sorted())

        guard case .capmas(let metadata) = result.metadata.details else {
            Issue.record("Expected CapMAS metadata")
            return
        }
        #expect(metadata.originalCaption == "A red can.")
        #expect(metadata.correctedCaption == "A can.")
        #expect(metadata.propositions.map(\.statement) == [
            "There is a can.", "The can is red."
        ])
        for proposition in metadata.propositions {
            #expect(proposition.score == 0 || proposition.score == 1)
            #expect(proposition.isTrue == (proposition.score > 0.5))
        }
    }

    @Test("CapMAS fails only after the initial decomposition plus five retries")
    func capmasDecompositionRetryLimit() async throws {
        let vision = CapMASFakeInferenceEngine(captionResponses: ["Caption."])
        let text = CapMASFakeInferenceEngine(
            textResponses: Array(repeating: "", count: 6)
        )
        let executor = try await CapMASBenchmarkExecutor(
            visionModelURL: URL(fileURLWithPath: "/tmp/vision.litertlm"),
            textModelURL: URL(fileURLWithPath: "/tmp/text.litertlm"),
            prompt: "Describe.",
            engineFactory: CapMASFakeEngineFactory(
                visionEngine: vision,
                textEngine: text
            )
        )
        var failed = false

        do {
            _ = try await executor.process(
                image: URL(fileURLWithPath: "/tmp/example.jpg")
            ) { _ in }
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(text.textPrompts.count == 6)
    }

    @Test("CapMAS parser, correction delimiters, settings, and filename")
    func capmasUtilitiesAndExport() {
        #expect(
            CapMASBenchmarkExecutor.parsePropositions(
                "1. First fact.\n\n2. Second fact."
            ) == ["First fact.", "Second fact."]
        )
        #expect(
            CapMASBenchmarkExecutor.stripCorrectionDelimiters(
                "prefix ### Corrected caption. ### suffix"
            ) == "Corrected caption."
        )

        let request = capmasRequest()
        #expect(request.exportedSettings.numSamples == 1)
        #expect(request.exportedSettings.algorithmSettings == .capmas)

        let output = BenchmarkOutput(
            runStartTime: .distantPast,
            runEndTime: .distantPast,
            iPhoneModel: "iPhone18,1",
            iPhoneIdentifier: "test-device",
            appVersion: "1",
            buildVersion: "1",
            osVersion: "26",
            algorithm: .capmas,
            imageCount: 25,
            completedImageCount: 0,
            benchmarkSettings: request.exportedSettings,
            results: BenchmarkResults(timing: []),
            metadata: [],
            status: .completed,
            failure: nil
        )
        #expect(
            output.exportFilename
                == "benchmark-capmas_test-device_gemma-4-e2b_gemma-4-e2b_describe_samples1.json"
        )
        #expect(output.formattedJSON().contains("\"classificationMethod\" : \"randomBinary\""))
        #expect(output.formattedJSON().contains("\"verificationThreshold\" : 0.5"))
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

    private func capmasRequest() -> BenchmarkRunRequest {
        let model = ResolvedBenchmarkModel(
            choice: .gemma4E2B,
            url: URL(fileURLWithPath: "/tmp/model.litertlm")
        )
        return BenchmarkRunRequest(
            algorithm: .capmas,
            visionModel: model,
            textModel: model,
            algorithmConfiguration: .capmas,
            prompt: BenchmarkPromptSettings(
                type: .describe,
                text: Prompts.describePrompt
            ),
            cooldownSeconds: 15
        )
    }
}

@MainActor
private final class CapMASFakeEngineFactory: EngineFactory {
    let visionEngine: CapMASFakeInferenceEngine
    let textEngine: CapMASFakeInferenceEngine

    init(
        visionEngine: CapMASFakeInferenceEngine,
        textEngine: CapMASFakeInferenceEngine
    ) {
        self.visionEngine = visionEngine
        self.textEngine = textEngine
    }

    func validateModel(at _: URL) throws {}

    func makeVisionEngine(modelURL _: URL) async throws -> any InferenceEngine {
        visionEngine
    }

    func makeTextEngine(modelURL _: URL) async throws -> any InferenceEngine {
        textEngine
    }
}

@MainActor
private final class CapMASFakeInferenceEngine:
    InferenceEngine,
    CapMASTextGenerating {
    private var captionResponses: [String]
    private var textResponses: [String]
    private(set) var captionPrompts: [String] = []
    private(set) var textPrompts: [String] = []

    init(
        captionResponses: [String] = [],
        textResponses: [String] = []
    ) {
        self.captionResponses = captionResponses
        self.textResponses = textResponses
    }

    func generateCaption(
        image _: URL,
        prompt: String,
        seed _: Int
    ) async throws -> String {
        captionPrompts.append(prompt)
        guard !captionResponses.isEmpty else {
            throw CapMASFakeError.unexpectedCall
        }
        return captionResponses.removeFirst()
    }

    func generateText(
        systemPrompt _: String,
        userPrompt: String
    ) async throws -> String {
        textPrompts.append(userPrompt)
        guard !textResponses.isEmpty else {
            throw CapMASFakeError.unexpectedCall
        }
        return textResponses.removeFirst()
    }

    func atomize(caption _: String) async throws -> AtomizationResult {
        throw CapMASFakeError.unexpectedCall
    }

    func repackage(atomics _: [String]) async throws -> String {
        throw CapMASFakeError.unexpectedCall
    }

    func cancel() async {}
}

private enum CapMASFakeError: Error {
    case unexpectedCall
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
