import Foundation
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
        #expect(fixture.factory.visionState.captionSeeds == [0, 1, 2])
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
            0: "red can with white logo",
            1: "red can",
            2: "red can with blue logo"
        ]
        factory.visionState.atomicResponses = [
            "red can with white logo": ["red can", "white logo"],
            "red can": ["red can"],
            "red can with blue logo": ["red can", "blue logo"]
        ]
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
    let visionState = FakeEngineState()
    let textState = FakeEngineState()

    func validateModel(at modelURL: URL) throws {
        events.append(.validate)
    }

    func makeVisionEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        events.append(.makeVision)
        return FakeInferenceEngine(state: visionState)
    }

    func makeTextEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        events.append(.makeText)
        return FakeInferenceEngine(state: textState)
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
