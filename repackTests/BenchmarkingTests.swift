#if BENCHMARKING
import LiteRTLM
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

    @Test("Exported policies match LiteRT configuration independently for each engine")
    func engineConfiguration() throws {
        let vision = InferenceEngineSettings(backend: .gpu, visionBackend: .gpu, mtpEnabled: false)
        let text = InferenceEngineSettings.text
        let run = resolved(request(cooldownSeconds: 7), visionSettings: vision, textSettings: text)
        for (policy, exported) in [(vision, run.exportedSettings.visionEngine), (text, run.exportedSettings.textEngine)] {
            let configuration = try policy.configuration(modelURL: URL(filePath: "/tmp/model.litertlm"))
            #expect(configuration.backend.rawValue == exported.backend)
            #expect(configuration.visionBackend?.rawValue == exported.visionBackend)
            #expect((configuration.speculativeDecodingConfig?.mode == .on) == exported.mtpEnabled)
        }
        let data = try JSONEncoder().encode(run.exportedSettings)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let visionJSON = try #require(json["visionEngine"] as? [String: Any])
        let textJSON = try #require(json["textEngine"] as? [String: Any])
        #expect(visionJSON["mtpEnabled"] as? Bool == false)
        #expect(textJSON["mtpEnabled"] as? Bool == true)
        #expect(json["cooldownSeconds"] as? Int == 7)
    }

    @Test("Embedding diagnostics are separate from elapsed totals and optional in JSON")
    func embeddingTimingExport() throws {
        let result = CaptionResult(
            captions: [], atomizedCaptions: [], scoredAtomics: [], retainedAtomics: [],
            caption: "", threshold: 0.5, scoringMetric: .semanticSimilarity,
            timings: [StageTiming(stage: .atomizing, duration: .seconds(3))],
            embeddingDuration: .seconds(2)
        )
        let semantic = BenchmarkImageTiming(file: "semantic.jpg", result: result, elapsed: .seconds(5))
        #expect(semantic.stages == ["atomization": 3])
        var noEmbedding = result
        noEmbedding.embeddingDuration = nil
        let plain = BenchmarkImageTiming(file: "plain.jpg", result: noEmbedding, elapsed: .seconds(3))
        let results = BenchmarkResults(timing: [semantic, plain])
        #expect(results.totalTime == 8)
        #expect(results.averageTime == 4)
        let data = try JSONEncoder().encode(results)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timing = try #require(json["timing"] as? [[String: Any]])
        let embedding = try #require(timing[0]["embedding"] as? [String: Any])
        #expect(embedding["totalTime"] as? Double == 2)
        #expect(timing[0]["totalTime"] as? Double == 5)
        #expect(timing[1]["embedding"] == nil)
        #expect(try JSONDecoder().decode(BenchmarkResults.self, from: data) == results)
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
        let runner = BenchmarkRunner(
            executorFactory: FakeExecutorFactory(executor: executor),
            imageProvider: FakeImageProvider(files: ["b.jpg", "a.jpg"]),
            sleeper: AdvancingSleeper(dateProvider: dateProvider),
            dateProvider: dateProvider,
            deviceInformationProvider: FakeDeviceInformationProvider()
        )

        let output = await runner.run(request: request()) { _ in }

        #expect(executor.processedFiles == ["a.jpg", "b.jpg"])
        #expect(output.results.totalTime == 5)
        #expect(output.results.averageTime == 2.5)
        #expect(output.runEndTime.timeIntervalSince(output.runStartTime) == 15)
        #expect(output.status == .completed)
    }

    @Test("All benchmarks release each executor before reloading", arguments: BenchmarkAlgorithm.allCases)
    func releasesEnginesBetweenImages(algorithm: BenchmarkAlgorithm) async {
        let factory = RecreatingExecutorFactory()
        let dateProvider = FakeDateProvider()
        let runner = BenchmarkRunner(
            executorFactory: factory,
            imageProvider: FakeImageProvider(files: ["a.jpg", "b.jpg", "c.jpg"]),
            sleeper: AdvancingSleeper(dateProvider: dateProvider),
            dateProvider: dateProvider,
            deviceInformationProvider: FakeDeviceInformationProvider()
        )
        let runRequest = switch algorithm {
        case .repack: request()
        case .capmas: capmasRequest()
        case .taco: tacoRequest(sampleCount: 3)
        }
        let output = await runner.run(request: runRequest) { _ in }

        #expect(factory.creationCount == 3)
        #expect(factory.previousWasReleased == [true, true, true])
        #expect(factory.resolutionCount == 1)
        #expect(factory.settings.allSatisfy { $0 == output.benchmarkSettings })
        #expect(output.benchmarkSettings.visionEngine.mtpEnabled == false)
        #expect(output.benchmarkSettings.textEngine.mtpEnabled == true)
        #expect(factory.previous == nil)
        #expect(output.status == .completed)
        #expect(output.completedImageCount == 3)
        #expect(output.results.totalTime == 3)
        #expect(output.runEndTime.timeIntervalSince(output.runStartTime) == 30)
    }

    @Test("All benchmarks preserve configuration and completed images on setup failure",
          arguments: BenchmarkAlgorithm.allCases, [1, 2])
    func reloadFailure(algorithm: BenchmarkAlgorithm, failingCreation: Int) async {
        let factory = RecreatingExecutorFactory(failingCreation: failingCreation)
        let dateProvider = FakeDateProvider()
        let runner = BenchmarkRunner(
            executorFactory: factory,
            imageProvider: FakeImageProvider(files: ["a.jpg", "b.jpg"]),
            sleeper: AdvancingSleeper(dateProvider: dateProvider),
            dateProvider: dateProvider,
            deviceInformationProvider: FakeDeviceInformationProvider()
        )
        let runRequest = switch algorithm {
        case .repack: request()
        case .capmas: capmasRequest()
        case .taco: tacoRequest(sampleCount: 3)
        }
        let output = await runner.run(request: runRequest) { _ in }

        #expect(factory.previousWasReleased == Array(repeating: true, count: failingCreation))
        #expect(factory.resolutionCount == 1)
        #expect(factory.settings.allSatisfy { $0 == output.benchmarkSettings })
        #expect(output.benchmarkSettings.visionEngine.mtpEnabled == false)
        #expect(output.benchmarkSettings.textEngine.mtpEnabled == true)
        #expect(factory.previous == nil)
        #expect(output.status == .failed)
        #expect(output.completedImageCount == failingCreation - 1)
        #expect(output.failure?.file == (failingCreation == 1 ? nil : "b.jpg"))
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
            deviceInformationProvider: FakeDeviceInformationProvider()
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
            benchmarkSettings: resolved(request).exportedSettings,
            results: BenchmarkResults(timing: []),
            metadata: [],
            status: .completed,
            failure: nil
        )

        let json = output.formattedJSON()
        #expect(json.contains("\"runStartTime\" : \"1970-01-01T00:00:00Z\""))
        #expect(json.contains("\"visionBackend\" : \"gpu\""))
        let object = try #require(JSONSerialization.jsonObject(with: output.formattedJSONData()) as? [String: Any])
        let settings = try #require(object["benchmarkSettings"] as? [String: Any])
        let vision = try #require(settings["visionEngine"] as? [String: Any])
        let text = try #require(settings["textEngine"] as? [String: Any])
        #expect(vision["mtpEnabled"] as? Bool == true)
        #expect(text["mtpEnabled"] as? Bool == true)
        #expect(vision["backend"] as? String == "gpu")
        #expect(vision["visionBackend"] as? String == "gpu")
        #expect(text["backend"] as? String == "gpu")
        #expect(text["visionBackend"] == nil)
        #expect(json.contains("\"similarityThreshold\" : 0.5"))
        #expect(
            output.exportFilename
                == "benchmark-repack_test-device_gemma-4-e2b_gemma-4-e2b_describe_samples5.json"
        )
    }

    @Test("Semantic exports identify BERTScore and the selected calibration")
    func bertScoreExport() throws {
        let original = request()
        let semantic = BenchmarkRunRequest(
            algorithm: .repack,
            visionModel: ResolvedBenchmarkModel(
                choice: .gemma4E4B, url: URL(filePath: DownloadableModel.e4b.fileName)
            ),
            textModel: ResolvedBenchmarkModel(
                choice: .gemma4E2B, url: URL(filePath: DownloadableModel.e2b.fileName)
            ),
            algorithmConfiguration: .repack(REPACKBenchmarkConfiguration(
                sampleCount: 9, scoringMetric: .semanticSimilarity
            )),
            prompt: original.prompt,
            cooldownSeconds: 0
        )
        let data = try JSONEncoder().encode(resolved(semantic).exportedSettings)
        let json = String(decoding: data, as: UTF8.self)
        #expect(resolved(semantic).exportedSettings.numSamples == 9)
        #expect(json.contains(SemanticCaptionScorer.implementation))
        #expect(json.contains(EmbeddingModelResources.modelFilename))
        #expect(json.contains(IDFCalibration.e4b.filename))
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
            #expect(proposition.isTrue == (proposition.score > CapMASBenchmarkExecutor.verificationThreshold))
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
        #expect(resolved(request).exportedSettings.numSamples == 1)
        #expect(resolved(request).exportedSettings.algorithmSettings == .capmas)

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
            benchmarkSettings: resolved(request).exportedSettings,
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

    @Test("TACO runs each stage, truncates reformulations, and counts responses")
    func tacoExecution() async throws {
        let vision = CapMASFakeInferenceEngine(
            captionResponses: [
                "A blue motorcycle.",
                "yes",
                "no",
                "unclear"
            ]
        )
        let text = CapMASFakeInferenceEngine(
            textResponses: [
                "",
                "1 | entity - whole (motorcycle)\n2 | attribute - color (motorcycle, blue)",
                "1 | Is there a motorcycle?\n2 | Is the motorcycle blue?",
                "1. Is a motorcycle present?\n2. Can you see a motorcycle?\n3. Is there a motorbike?",
                "1. Does the motorcycle look blue?",
                "A motorcycle."
            ]
        )
        let executor = try await TACOBenchmarkExecutor(
            visionModelURL: URL(fileURLWithPath: "/tmp/vision.litertlm"),
            textModelURL: URL(fileURLWithPath: "/tmp/text.litertlm"),
            prompt: "Describe the product.",
            reformulationCount: 2,
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

        #expect(text.textPrompts.count == 6)
        #expect(vision.captionPrompts.count == 4)
        #expect(result.timing.stages.keys.sorted() == [
            "captioning",
            "queryGeneration",
            "refinement",
            "reformulation",
            "tupleExtraction",
            "verification"
        ])
        let verificationProgress = progress.compactMap {
            $0.stage?.id == "verification" ? $0.fractionCompleted : nil
        }
        #expect(verificationProgress == verificationProgress.sorted())

        guard case .taco(let metadata) = result.metadata.details else {
            Issue.record("Expected TACO metadata")
            return
        }
        #expect(metadata.originalCaption == "A blue motorcycle.")
        #expect(metadata.atomicTuples.count == 2)
        #expect(metadata.queries.count == 2)
        #expect(metadata.queries[0].verifications.count == 2)
        #expect(metadata.queries[0].yesCount == 1)
        #expect(metadata.queries[0].noCount == 1)
        #expect(metadata.queries[0].confidence == 0.5)
        #expect(metadata.queries[0].majorityAnswer == "yes")
        #expect(metadata.queries[1].yesCount == 0)
        #expect(metadata.queries[1].confidence == 0)
        #expect(metadata.refinedCaption == "A motorcycle.")
    }

    @Test("TACO parsers handle structured and line output")
    func tacoParsers() {
        #expect(
            TACOBenchmarkExecutor.parseTuples(
                """
                {atomic_tuples: [
                  {tuple_type: "entity - whole", relevant_words: ["can"]},
                  {tuple_type: "attribute - color", relevant_words: ["can", "red"]}
                ]}
                """
            ) == [
                "entity - whole (can)",
                "attribute - color (can, red)"
            ]
        )
        #expect(
            TACOBenchmarkExecutor.parseQuestions(
                """
                {atomic_queries: ["Is there a can?", "Is the can red?"]}
                """
            ) == ["Is there a can?", "Is the can red?"]
        )
        #expect(
            TACOBenchmarkExecutor.parseQuestions(
                "1 | Is there a can?\n- Does the can look red?"
            ) == ["Is there a can?", "Does the can look red?"]
        )
        #expect(
            TACOBenchmarkExecutor.parseQuestions(
                "['Is there a can?', 'Is the can red?']"
            ) == ["Is there a can?", "Is the can red?"]
        )
        #expect(TACOBenchmarkExecutor.isYes(" Yes.\n"))
        #expect(!TACOBenchmarkExecutor.isYes("maybe"))
    }

    @Test("TACO fails after six unusable tuple responses")
    func tacoRetryLimit() async throws {
        let vision = CapMASFakeInferenceEngine(captionResponses: ["Caption."])
        let text = CapMASFakeInferenceEngine(
            textResponses: Array(repeating: "", count: 6)
        )
        let executor = try await TACOBenchmarkExecutor(
            visionModelURL: URL(fileURLWithPath: "/tmp/vision.litertlm"),
            textModelURL: URL(fileURLWithPath: "/tmp/text.litertlm"),
            prompt: "Describe.",
            reformulationCount: 2,
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

    @Test("TACO exports its sample count and filename")
    func tacoExport() {
        let request = tacoRequest(sampleCount: 3)
        #expect(resolved(request).exportedSettings.numSamples == 3)
        #expect(resolved(request).exportedSettings.algorithmSettings == .taco)

        let output = BenchmarkOutput(
            runStartTime: .distantPast,
            runEndTime: .distantPast,
            iPhoneModel: "iPhone18,1",
            iPhoneIdentifier: "test-device",
            appVersion: "1",
            buildVersion: "1",
            osVersion: "26",
            algorithm: .taco,
            imageCount: 25,
            completedImageCount: 0,
            benchmarkSettings: resolved(request).exportedSettings,
            results: BenchmarkResults(timing: []),
            metadata: [],
            status: .completed,
            failure: nil
        )

        #expect(
            output.exportFilename
                == "benchmark-taco_test-device_gemma-4-e2b_gemma-4-e2b_describe_samples3.json"
        )
        #expect(output.formattedJSON().contains("\"algorithm\" : \"TACO\""))
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

    private func tacoRequest(sampleCount: Int) -> BenchmarkRunRequest {
        let model = ResolvedBenchmarkModel(
            choice: .gemma4E2B,
            url: URL(fileURLWithPath: "/tmp/model.litertlm")
        )
        return BenchmarkRunRequest(
            algorithm: .taco,
            visionModel: model,
            textModel: model,
            algorithmConfiguration: .taco(sampleCount: sampleCount),
            prompt: BenchmarkPromptSettings(
                type: .describe,
                text: Prompts.describePrompt
            ),
            cooldownSeconds: 15
        )
    }
}

private func resolved(
    _ request: BenchmarkRunRequest,
    visionSettings: InferenceEngineSettings = .vision,
    textSettings: InferenceEngineSettings = .text
) -> ResolvedBenchmarkRun {
    ResolvedBenchmarkRun(
        request: request,
        visionSettings: visionSettings,
        textSettings: textSettings,
        embeddingResources: EmbeddingModelResources(
            modelURL: URL(filePath: "/tmp/" + EmbeddingModelResources.modelFilename),
            tokenizerURL: URL(filePath: "/tmp/" + EmbeddingModelResources.tokenizerFilename)
        )
    )
}

@MainActor
private final class CapMASFakeEngineFactory: EngineFactory {
    let visionSettings = InferenceEngineSettings.vision
    let textSettings = InferenceEngineSettings.text
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
private final class CapMASFakeInferenceEngine: InferenceEngine {
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
private final class RecreatingExecutorFactory: BenchmarkAlgorithmExecutorBuilding {
    weak var previous: FakeBenchmarkExecutor?
    var creationCount = 0
    var resolutionCount = 0
    var settings: [BenchmarkSettings] = []
    var previousWasReleased: [Bool] = []
    let failingCreation: Int?

    init(failingCreation: Int? = nil) {
        self.failingCreation = failingCreation
    }

    func resolve(_ request: BenchmarkRunRequest) -> ResolvedBenchmarkRun {
        resolutionCount += 1
        return resolved(request, visionSettings: InferenceEngineSettings(
            backend: .gpu, visionBackend: .gpu, mtpEnabled: false
        ))
    }

    func makeExecutor(for run: ResolvedBenchmarkRun) async throws
        -> any BenchmarkAlgorithmExecuting {
        settings.append(run.exportedSettings)
        previousWasReleased.append(previous == nil)
        creationCount += 1
        if creationCount == failingCreation {
            throw FakeBenchmarkExecutor.Failure.expected
        }
        let executor = FakeBenchmarkExecutor(durations: [:])
        previous = executor
        return executor
    }
}

@MainActor
private final class FakeExecutorFactory: BenchmarkAlgorithmExecutorBuilding {
    let executor: FakeBenchmarkExecutor

    init(executor: FakeBenchmarkExecutor) {
        self.executor = executor
    }

    func resolve(_ request: BenchmarkRunRequest) -> ResolvedBenchmarkRun {
        resolved(request)
    }

    func makeExecutor(for run: ResolvedBenchmarkRun) async throws
        -> any BenchmarkAlgorithmExecuting {
        executor
    }
}

@MainActor
private final class FakeBenchmarkExecutor: BenchmarkAlgorithmExecuting {
    enum Failure: Error {
        case expected
    }

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
                stage: BenchmarkAlgorithm.repack.stages.first,
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

private extension Duration {
    nonisolated var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
