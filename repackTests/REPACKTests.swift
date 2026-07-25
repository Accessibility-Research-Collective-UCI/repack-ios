import Foundation
@preconcurrency import LiteRTLM
import Testing
@testable import repack

@Suite("REPACK")
@MainActor
struct REPACKTests {
    @Test("Prompt options resolve through replaceable constants")
    func promptResolution() {
        #expect(REPACKPrompt.product.resolvedText == REPACKPrompts.productPrompt)
        #expect(REPACKPrompt.describe.resolvedText == REPACKPrompts.describePrompt)
        #expect(REPACKPrompt.custom("  Custom caption request. \n").resolvedText == "Custom caption request.")
    }

    @Test("Process generates N plus one captions and caches scoring for regeneration")
    func completePipelineAndRegeneration() async throws {
        let fixture = Fixture()
        let repack = try await REPACK(
            modelURL: fixture.modelURL,
            engineFactory: fixture.factory
        )
        var progress: [REPACKProgress] = []

        let result = try await repack.process(
            image: fixture.imageURL,
            samplePrompt: .describe,
            sampleCount: 2,
            threshold: 0.75
        ) {
            progress.append($0)
        }

        #expect(fixture.factory.events == [.validate, .makeVision])
        #expect(fixture.factory.visionState.captionSeeds == [1, 2, 3])
        #expect(result.captions.map(\.index) == [0, 1, 2])
        #expect(result.captions.map(\.kind) == [.reference, .sample, .sample])
        #expect(result.atomizedCaptions.count == 3)
        #expect(result.scoredAtomics.count == 2)
        #expect(result.scoredAtomics[0].averageScore == 1)
        #expect(abs(result.scoredAtomics[1].averageScore - 0.25) <= 1e-12)
        #expect(result.retainedAtomics == ["red can"])
        #expect(result.caption == "red can")
        #expect(progress.contains(.sampling(completed: 3, total: 3)))
        #expect(progress.contains(.atomizing(completed: 3, total: 3)))

        let captionCallCount = fixture.factory.visionState.captionSeeds.count
        let atomizeCallCount = fixture.factory.visionState.atomizedCaptions.count
        let regenerated = try await repack.regenerateCaption(threshold: 0.2)

        #expect(regenerated.retainedAtomics == ["red can", "white logo"])
        #expect(regenerated.caption == "red can | white logo")
        #expect(fixture.factory.visionState.captionSeeds.count == captionCallCount)
        #expect(fixture.factory.visionState.atomizedCaptions.count == atomizeCallCount)
        #expect(fixture.factory.visionState.repackagedAtomics.count == 2)
    }

    @Test("E4B samples with vision while E2B performs text processing")
    func hybridEngineRoles() async throws {
        let fixture = Fixture()
        let e4BURL = URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm")
        let e2BURL = URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm")
        let repack = try await REPACK(
            samplingModelURL: e4BURL,
            processingModelURL: e2BURL,
            engineFactory: fixture.factory,
            devicePolicy: REPACKDevicePolicy(modelIdentifier: "iPhone18,1")
        )

        let result = try await repack.process(
            image: fixture.imageURL,
            samplePrompt: .describe,
            sampleCount: 2,
            threshold: 0.75
        )

        #expect(fixture.factory.events == [.validate, .makeVision, .validate, .makeText])
        #expect(fixture.factory.visionModelURLs == [e4BURL])
        #expect(fixture.factory.textModelURLs == [e2BURL])
        #expect(fixture.factory.visionState.captionSeeds == [1, 2, 3])
        #expect(fixture.factory.visionState.atomizedCaptions.isEmpty)
        #expect(fixture.factory.visionState.repackagedAtomics.isEmpty)
        #expect(fixture.factory.textState.atomizedCaptions.count == 3)
        #expect(fixture.factory.textState.repackagedAtomics == [["red can"]])
        #expect(result.caption == "red can")
    }

    @Test("Device generations select the intended E4B policy")
    func devicePolicies() {
        for identifier in ["iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2"] {
            #expect(REPACKDevicePolicy(modelIdentifier: identifier).e4BMode == .unavailable)
        }

        for identifier in [
            "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4", "iPhone17,5",
            "iPhone18,3", "iPhone18,5"
        ] {
            #expect(REPACKDevicePolicy(modelIdentifier: identifier).e4BMode == .adaptive)
        }

        for identifier in ["iPhone18,1", "iPhone18,2", "iPhone18,4"] {
            #expect(REPACKDevicePolicy(modelIdentifier: identifier).e4BMode == .resident)
        }
    }

    @Test("iPhone 15 rejects E4B")
    func iPhone15RejectsE4B() async {
        let fixture = Fixture()

        await #expect(throws: REPACKError.e4BUnavailableOnDevice) {
            try await REPACK(
                samplingModelURL: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
                processingModelURL: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
                engineFactory: fixture.factory,
                devicePolicy: REPACKDevicePolicy(modelIdentifier: "iPhone16,1")
            )
        }
        #expect(fixture.factory.events.isEmpty)
    }

    @Test("iPhone 15 model controls only allow E2B")
    func iPhone15ModelAvailability() {
        let fixture = Fixture()
        let viewModel = REPACKViewModel(
            engineFactory: fixture.factory,
            devicePolicy: REPACKDevicePolicy(modelIdentifier: "iPhone15,4")
        )
        let e2BURL = URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm")
        let e4BURL = URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm")

        #expect(viewModel.supportsModel(at: e2BURL))
        #expect(!viewModel.supportsModel(at: e4BURL))
        #expect(viewModel.supportsDownload(.e2b))
        #expect(!viewModel.supportsDownload(.e4b))
    }

    @Test("Adaptive devices keep both engines resident with sufficient memory")
    func adaptiveResidentEngines() async throws {
        let fixture = Fixture()
        let repack = try await REPACK(
            samplingModelURL: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
            processingModelURL: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
            engineFactory: fixture.factory,
            devicePolicy: REPACKDevicePolicy(modelIdentifier: "iPhone17,3"),
            memoryProvider: FixedMemoryProvider(
                bytes: REPACKDevicePolicy.minimumAvailableForResidentEngines
            )
        )

        #expect(fixture.factory.events == [.validate, .makeVision, .validate, .makeText])
        #expect(fixture.factory.visionEngine != nil)
        #expect(fixture.factory.textEngine != nil)
        _ = repack
    }

    @Test("Adaptive devices switch from E4B to E2B when memory is constrained")
    func adaptiveSequentialEngines() async throws {
        let fixture = Fixture()
        let repack = try await REPACK(
            samplingModelURL: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
            processingModelURL: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
            engineFactory: fixture.factory,
            devicePolicy: REPACKDevicePolicy(modelIdentifier: "iPhone18,3"),
            memoryProvider: FixedMemoryProvider(
                bytes: REPACKDevicePolicy.minimumAvailableForResidentEngines - 1
            )
        )

        #expect(fixture.factory.events == [.validate, .makeVision, .validate])
        let result = try await repack.process(
            image: fixture.imageURL,
            samplePrompt: .describe,
            sampleCount: 2,
            threshold: 0.75
        )

        #expect(fixture.factory.events == [.validate, .makeVision, .validate, .makeText])
        #expect(fixture.factory.visionEngine == nil)
        #expect(fixture.factory.textEngine != nil)
        #expect(fixture.factory.visionState.captionSeeds == [1, 2, 3])
        #expect(fixture.factory.textState.atomizedCaptions.count == 3)
        #expect(result.caption == "red can")
    }

    @Test("Model selection resolves E2B processing only when E4B samples")
    func processingModelResolution() throws {
        let e2B = LocalModel(
            url: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
            isBundled: false
        )
        let e4B = LocalModel(
            url: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
            isBundled: false
        )

        #expect(
            ModelManager.processingModelURL(
                for: e2B.url,
                availableModels: [e2B, e4B]
            ) == e2B.url
        )
        #expect(
            ModelManager.processingModelURL(
                for: e4B.url,
                availableModels: [e4B, e2B]
            ) == e2B.url
        )
        #expect(
            ModelManager.processingModelURL(
                for: e4B.url,
                availableModels: [e4B]
            ) == nil
        )
    }

    @Test("Scoring uses the reference atomic as the BLEU candidate")
    func scoreDirectionAndEmptySamples() async throws {
        let fixture = Fixture()
        let repack = try await REPACK(
            modelURL: fixture.modelURL,
            engineFactory: fixture.factory
        )

        let results = try await repack.score(
            referenceAtoms: ["red metal can"],
            sampleAtoms: [
                ["red can", "blue box"],
                []
            ]
        )

        let score = try #require(results.first)
        #expect(score.matches.count == 2)
        #expect(score.matches[0].statement == "red can")
        #expect(abs(score.matches[0].score - (2.0 / 3.0)) <= 1e-12)
        #expect(score.matches[1].statement == nil)
        #expect(score.matches[1].score == 0)
        #expect(abs(score.averageScore - (1.0 / 3.0)) <= 1e-12)
    }

    @Test("Threshold comparison is inclusive and an empty selection abstains")
    func inclusiveThresholdAndAbstention() async throws {
        let fixture = Fixture()
        let repack = try await REPACK(
            modelURL: fixture.modelURL,
            engineFactory: fixture.factory
        )

        _ = try await repack.process(
            image: fixture.imageURL,
            samplePrompt: .describe,
            sampleCount: 2,
            threshold: 0.75
        )

        let inclusive = try await repack.regenerateCaption(threshold: 1)
        #expect(inclusive.retainedAtomics == ["red can"])

        let abstention = try await repack.repackage(
            referenceAtomsAndScores: [
                REPACKScoredAtomic(
                    index: 0,
                    statement: "unsupported detail",
                    matches: [],
                    averageScore: 0.49
                )
            ],
            threshold: 0.5
        )
        #expect(abstention.contains("could not verify enough details"))
    }

    @Test("Threshold debounce cancels stale requests and publishes the latest value")
    func thresholdDebounce() async throws {
        let fixture = Fixture()
        let viewModel = REPACKViewModel(engineFactory: fixture.factory)

        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )
        viewModel.selectedImageURL = fixture.imageURL
        viewModel.sampleCount = 2
        viewModel.startProcessing()
        try await waitUntil { viewModel.phase == .output }

        let initialRepackages = fixture.factory.visionState.repackagedAtomics.count
        viewModel.updateThreshold(0.2)
        try await Task.sleep(for: .milliseconds(100))
        viewModel.updateThreshold(0.8)
        try await Task.sleep(for: .milliseconds(800))

        #expect(fixture.factory.visionState.repackagedAtomics.count == initialRepackages + 1)
        #expect(viewModel.result?.threshold == 0.8)
        #expect(viewModel.result?.retainedAtomics == ["red can"])
        #expect(!viewModel.isRegenerating)
    }

    @Test("Structured atomization tool publishes one isolated array")
    func structuredToolCapture() async throws {
        let sink = AtomicStatementsSink()
        var tool = SubmitAtomicStatementsTool()
        tool.statements = [" A red can. ", "", "A red can.", "A logo is visible."]

        _ = try await AtomicStatementsContext.$sink.withValue(sink) {
            try await tool.run()
        }

        let captured = await sink.take()
        #expect(captured.submissionCount == 1)
        #expect(captured.statements == [" A red can. ", "", "A red can.", "A logo is visible."])
    }

    @Test("Structured atomization tool schema contains only statements")
    func structuredToolSchema() throws {
        let schema = SubmitAtomicStatementsTool().getSchema()
        let function = try #require(schema["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let statements = try #require(properties["statements"] as? [String: Any])

        #expect(function["name"] as? String == "submit_atomic_statements")
        #expect(Set(properties.keys) == ["statements"])
        #expect(statements["type"] as? String == "array")
    }

    @Test("Atomization retries a native tool-call parse failure in a fresh attempt")
    func atomizationToolCallRetry() async throws {
        var attempts: [Int] = []
        let result: String = try await AtomizationRetryPolicy.run { attempt in
            attempts.append(attempt)
            if attempt == 0 {
                throw LiteRTLMError.conversation(
                    .invalidResponse("Native sendMessage returned null.")
                )
            }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(attempts == [0, 1])
        #expect(
            AtomizationRetryPolicy.shouldRetry(
                LiteRTLMError.conversation(
                    .toolExecutionError(
                        name: "submit_atomic",
                        error: "Tool 'submit_atomic' not found."
                    )
                )
            )
        )
    }

    @Test("Atomization does not retry unrelated runtime failures")
    func atomizationDoesNotRetryUnrelatedFailure() async {
        var attemptCount = 0

        await #expect(throws: StructuredAtomizationError.missingCaptureContext) {
            let _: String = try await AtomizationRetryPolicy.run { _ in
                attemptCount += 1
                throw StructuredAtomizationError.missingCaptureContext
            }
        }

        #expect(attemptCount == 1)
    }

    @Test("Atomization surfaces a tool-call parse failure after one retry")
    func atomizationRetryLimit() async {
        let failure = LiteRTLMError.conversation(
            .invalidResponse("Native sendMessage returned null.")
        )
        var attemptCount = 0

        await #expect(throws: failure) {
            let _: String = try await AtomizationRetryPolicy.run { _ in
                attemptCount += 1
                throw failure
            }
        }

        #expect(attemptCount == AtomizationRetryPolicy.maximumAttempts)
    }

    @Test("Invalid inputs fail before inference")
    func validation() async throws {
        let fixture = Fixture()
        let repack = try await REPACK(
            modelURL: fixture.modelURL,
            engineFactory: fixture.factory
        )

        await #expect(throws: REPACKError.invalidSampleCount(0)) {
            try await repack.sample(
                image: fixture.imageURL,
                prompt: .describe,
                count: 0
            )
        }
        await #expect(throws: REPACKError.emptyPrompt) {
            try await repack.sample(
                image: fixture.imageURL,
                prompt: .custom(" \n"),
                count: 1
            )
        }
        await #expect(throws: REPACKError.invalidThreshold(1.1)) {
            try await repack.process(
                image: fixture.imageURL,
                samplePrompt: .describe,
                sampleCount: 1,
                threshold: 1.1
            )
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for REPACK state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct Fixture {
    let modelURL = URL(fileURLWithPath: "/tmp/fake-model.litertlm")
    let imageURL = URL(fileURLWithPath: "/tmp/fake-image.jpg")
    let factory = FakeEngineFactory()

    init() {
        factory.visionState.captionResponses = [
            1: "red can with white logo",
            2: "red can",
            3: "red can with blue logo"
        ]
        factory.visionState.atomicResponses = [
            "red can with white logo": ["red can", "white logo"],
            "red can": ["red can"],
            "red can with blue logo": ["red can", "blue logo"]
        ]
        factory.textState.atomicResponses = factory.visionState.atomicResponses
    }
}

@MainActor
private final class FakeEngineFactory: REPACKEngineFactory {
    enum Event: Equatable {
        case validate
        case makeVision
        case makeText
    }

    var events: [Event] = []
    var validatedModelURLs: [URL] = []
    var visionModelURLs: [URL] = []
    var textModelURLs: [URL] = []
    let visionState = FakeEngineState()
    let textState = FakeEngineState()
    private(set) weak var visionEngine: FakeInferenceEngine?
    private(set) weak var textEngine: FakeInferenceEngine?

    func validateModel(at modelURL: URL) throws {
        events.append(.validate)
        validatedModelURLs.append(modelURL)
    }

    func makeVisionEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        events.append(.makeVision)
        visionModelURLs.append(modelURL)
        let engine = FakeInferenceEngine(state: visionState)
        visionEngine = engine
        return engine
    }

    func makeTextEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        events.append(.makeText)
        textModelURLs.append(modelURL)
        let engine = FakeInferenceEngine(state: textState)
        textEngine = engine
        return engine
    }
}

nonisolated private struct FixedMemoryProvider: REPACKMemoryProviding {
    let bytes: UInt64

    func availableMemory() -> UInt64 {
        bytes
    }
}

@MainActor
private final class FakeEngineState {
    var captionResponses: [Int: String] = [:]
    var atomicResponses: [String: [String]] = [:]
    var captionSeeds: [Int] = []
    var atomizedCaptions: [String] = []
    var repackagedAtomics: [[String]] = []
    var cancellationCount = 0
}

@MainActor
private final class FakeInferenceEngine: REPACKInferenceEngine {
    let state: FakeEngineState

    init(state: FakeEngineState) {
        self.state = state
    }

    func generateCaption(image: URL, prompt: String, seed: Int) async throws -> String {
        state.captionSeeds.append(seed)
        return state.captionResponses[seed] ?? "caption \(seed)"
    }

    func atomize(caption: String) async throws -> [String] {
        state.atomizedCaptions.append(caption)
        return state.atomicResponses[caption] ?? [caption]
    }

    func repackage(atomics: [String]) async throws -> String {
        state.repackagedAtomics.append(atomics)
        return atomics.joined(separator: " | ")
    }

    func cancel() async {
        state.cancellationCount += 1
    }
}
