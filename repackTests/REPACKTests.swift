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

    @Test("Model URLs resolve to user-facing names and descriptions")
    func modelPresentation() throws {
        let e2BURL = URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm")
        let e4BURL = URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm")
        let e2B = try #require(DownloadableModel(modelURL: e2BURL))
        let e4B = try #require(DownloadableModel(modelURL: e4BURL))

        #expect(e2B.displayName == "Gemma 4 E2B")
        #expect(e2B.shortDescription == "Runs on your device. Fastest captions.")
        #expect(e4B.displayName == "Gemma 4 E4B")
        #expect(e4B.shortDescription.contains("Gemma 4 E2B is also needed"))

        let viewModel = REPACKViewModel()
        viewModel.modelURL = e4BURL
        viewModel.localModels = [
            LocalModel(url: e4BURL, isBundled: false),
            LocalModel(url: e2BURL, isBundled: false)
        ]
        #expect(viewModel.selectedModelName == "Gemma 4 E4B")
        #expect(viewModel.verificationModelName == "Gemma 4 E2B")

        viewModel.promptChoice = .custom
        viewModel.customPrompt = "  Focus on readable text.  "
        #expect(viewModel.promptDisplayText == "Focus on readable text.")
    }

    @Test("Verification defaults to fifty percent")
    func defaultVerificationThreshold() {
        let viewModel = REPACKViewModel()

        #expect(viewModel.threshold == 0.5)
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

        #expect(fixture.factory.events == [.validate, .makeVision, .makeText])
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
        let atomizeCallCount = fixture.factory.textState.atomizedCaptions.count
        let regenerated = try await repack.regenerateCaption(threshold: 0.2)

        #expect(regenerated.retainedAtomics == ["red can", "white logo"])
        #expect(regenerated.caption == "red can | white logo")
        #expect(fixture.factory.visionState.captionSeeds.count == captionCallCount)
        #expect(fixture.factory.textState.atomizedCaptions.count == atomizeCallCount)
        #expect(fixture.factory.textState.repackagedAtomics.count == 2)
    }

    @Test("An unparseable reference swaps with the first parseable sample")
    func referencePromotion() async throws {
        let fixture = Fixture()
        fixture.factory.textState.atomicResponses["red can with white logo"] = []
        fixture.factory.textState.atomizationStatuses["red can with white logo"] = .unparseable
        fixture.factory.textState.atomicResponses["red can"] = []
        fixture.factory.textState.atomizationStatuses["red can"] = .unparseable
        let repack = try await REPACK(
            modelURL: fixture.modelURL,
            engineFactory: fixture.factory
        )

        let result = try await repack.process(
            image: fixture.imageURL,
            samplePrompt: .describe,
            sampleCount: 2,
            threshold: 0.5
        )

        #expect(
            result.captions.map(\.text)
                == ["red can with blue logo", "red can", "red can with white logo"]
        )
        #expect(result.captions.map(\.index) == [0, 1, 2])
        #expect(result.captions.map(\.kind) == [.reference, .sample, .sample])
        #expect(
            result.atomizedCaptions.map(\.status)
                == [.parsed, .unparseable, .unparseable]
        )
        #expect(result.atomizedCaptions[0].statements == ["red can", "blue logo"])
        #expect(result.atomizedCaptions[1].statements.isEmpty)
        #expect(result.atomizedCaptions[2].statements.isEmpty)
        #expect(result.scoredAtomics.allSatisfy { atomic in
            atomic.matches.allSatisfy { $0.statement == nil && $0.score == 0 }
        })
        #expect(result.caption.contains("could not verify enough details"))

        let regenerated = try await repack.regenerateCaption(threshold: 0.9)
        #expect(regenerated.captions == result.captions)
        #expect(regenerated.atomizedCaptions == result.atomizedCaptions)
    }

    @Test("All unparseable captions preserve ordering and finish with abstention")
    func allAtomizationsFail() async throws {
        let fixture = Fixture()
        for caption in Array(fixture.factory.textState.atomicResponses.keys) {
            fixture.factory.textState.atomicResponses[caption] = []
            fixture.factory.textState.atomizationStatuses[caption] = .unparseable
        }
        let repack = try await REPACK(
            modelURL: fixture.modelURL,
            engineFactory: fixture.factory
        )

        let result = try await repack.process(
            image: fixture.imageURL,
            samplePrompt: .describe,
            sampleCount: 2,
            threshold: 0.5
        )

        #expect(
            result.captions.map(\.text)
                == ["red can with white logo", "red can", "red can with blue logo"]
        )
        #expect(result.atomizedCaptions.allSatisfy { $0.status == .unparseable })
        #expect(result.scoredAtomics.isEmpty)
        #expect(result.retainedAtomics.isEmpty)
        #expect(result.caption.contains("could not verify enough details"))
        #expect(fixture.factory.textState.repackagedAtomics.isEmpty)
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

        let initialRepackages = fixture.factory.textState.repackagedAtomics.count
        viewModel.updateThreshold(0.2)
        try await Task.sleep(for: .milliseconds(100))
        viewModel.updateThreshold(0.8)
        try await Task.sleep(for: .milliseconds(800))

        #expect(fixture.factory.textState.repackagedAtomics.count == initialRepackages + 1)
        #expect(viewModel.result?.threshold == 0.8)
        #expect(viewModel.result?.retainedAtomics == ["red can"])
        #expect(!viewModel.isRegenerating)
    }

    @Test("Foreground-only captioning ignores inactive and cancels on background")
    func foregroundOnlyBackgroundCancellation() async throws {
        let fixture = Fixture()
        fixture.factory.visionState.captionDelay = .seconds(5)
        let executionCoordinator = FakeCaptionExecutionCoordinator(mode: .foregroundOnly)
        let pendingRunStore = FakePendingCaptionRunStore()
        let viewModel = REPACKViewModel(
            engineFactory: fixture.factory,
            captionExecutionCoordinator: executionCoordinator,
            pendingRunStore: pendingRunStore
        )

        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )
        viewModel.selectedImageURL = fixture.imageURL
        viewModel.sampleCount = 2
        viewModel.startProcessing()

        await viewModel.handleScenePhase(.inactive)
        #expect(viewModel.phase == .processing)

        await viewModel.handleScenePhase(.background)

        guard case .interrupted = viewModel.phase else {
            Issue.record("Expected foreground-only captioning to become interrupted")
            return
        }
        #expect(fixture.factory.visionState.cancellationCount == 1)
        #expect(executionCoordinator.completions == [false])
        #expect(pendingRunStore.run != nil)
    }

    @Test("Scene activation does not load a model without explicit selection")
    func modelLoadingRequiresExplicitSelection() async {
        let fixture = Fixture()
        let viewModel = REPACKViewModel(engineFactory: fixture.factory)
        viewModel.modelURL = fixture.modelURL
        viewModel.localModels = [
            LocalModel(url: fixture.modelURL, isBundled: false)
        ]
        viewModel.phase = .missingModel

        await viewModel.handleScenePhase(.inactive)
        await viewModel.handleScenePhase(.background)
        await viewModel.handleScenePhase(.active)

        #expect(fixture.factory.events.isEmpty)
        #expect(viewModel.phase == .missingModel)

        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )

        #expect(fixture.factory.events == [.validate, .makeVision, .makeText])
        #expect(viewModel.phase == .ready)
    }

    @Test("Model selection is visible before loading begins")
    func modelSelectionPrecedesLoading() async {
        let fixture = Fixture()
        let viewModel = REPACKViewModel(engineFactory: fixture.factory)
        let localModel = LocalModel(url: fixture.modelURL, isBundled: false)
        viewModel.localModels = [localModel]

        await viewModel.prepareModelSelection(localModel)

        #expect(ModelManager.sameFile(viewModel.modelURL, fixture.modelURL))
        #expect(viewModel.phase == .missingModel)
        #expect(fixture.factory.events.isEmpty)

        await viewModel.loadPreparedModel()

        #expect(fixture.factory.events == [.validate, .makeVision, .makeText])
        #expect(viewModel.phase == .ready)
    }

    @Test("Cancelling a model download leaves the previous model unloaded")
    func cancellingDownloadLeavesModelUnloaded() async throws {
        let fixture = Fixture()
        let downloadService = LifecycleModelDownloadService(mode: .waitForCancellation)
        let viewModel = REPACKViewModel(
            modelManager: ModelManager(downloadService: downloadService),
            engineFactory: fixture.factory,
            modelDownloadExecutionCoordinator: FakeModelDownloadExecutionCoordinator(),
            modelDownloadNotifier: FakeModelDownloadNotifier()
        )
        let localModel = LocalModel(url: fixture.modelURL, isBundled: false)
        viewModel.localModels = [localModel]
        await viewModel.selectModel(localModel)
        let loadedEvents = fixture.factory.events

        viewModel.confirmForegroundModelDownload(modelDownloadPlan())
        try await waitUntil { fixture.factory.visionEngine == nil }
        await viewModel.cancelModelDownload()
        await viewModel.handleScenePhase(.active)

        #expect(viewModel.phase == .missingModel)
        #expect(!viewModel.isEngineReady)
        #expect(fixture.factory.events == loadedEvents)
        #expect(fixture.factory.visionState.cancellationCount == 1)
    }

    @Test("A completed model download remains unloaded")
    func completedDownloadLeavesModelUnloaded() async throws {
        let fixture = Fixture()
        let downloadService = LifecycleModelDownloadService(
            mode: .complete(.installed(fixture.modelURL))
        )
        let viewModel = REPACKViewModel(
            modelManager: ModelManager(downloadService: downloadService),
            engineFactory: fixture.factory,
            modelDownloadExecutionCoordinator: FakeModelDownloadExecutionCoordinator(),
            modelDownloadNotifier: FakeModelDownloadNotifier()
        )
        let localModel = LocalModel(url: fixture.modelURL, isBundled: false)
        viewModel.localModels = [localModel]
        await viewModel.selectModel(localModel)
        let loadedEvents = fixture.factory.events

        viewModel.confirmForegroundModelDownload(modelDownloadPlan())
        try await waitUntil {
            !viewModel.isModelDownloadActive && viewModel.phase == .missingModel
        }
        await viewModel.handleScenePhase(.active)

        #expect(!viewModel.isEngineReady)
        #expect(fixture.factory.events == loadedEvents)
        #expect(fixture.factory.visionState.cancellationCount == 1)
    }

    @Test("Background-protected captioning continues when the scene backgrounds")
    func protectedBackgroundContinuation() async throws {
        let fixture = Fixture()
        fixture.factory.visionState.captionDelay = .seconds(5)
        let executionCoordinator = FakeCaptionExecutionCoordinator(
            mode: .backgroundProtected
        )
        let pendingRunStore = FakePendingCaptionRunStore()
        let viewModel = REPACKViewModel(
            engineFactory: fixture.factory,
            captionExecutionCoordinator: executionCoordinator,
            pendingRunStore: pendingRunStore
        )

        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )
        viewModel.selectedImageURL = fixture.imageURL
        viewModel.startProcessing()

        await viewModel.handleScenePhase(.background)

        #expect(viewModel.phase == .processing)
        #expect(executionCoordinator.completions.isEmpty)
        #expect(pendingRunStore.run != nil)

        await viewModel.resetRun()
        #expect(pendingRunStore.run == nil)
        #expect(executionCoordinator.completions == [false])
    }

    @Test("Successful captioning clears recovery metadata and completes the task")
    func successfulRunClearsRecoveryState() async throws {
        let fixture = Fixture()
        let executionCoordinator = FakeCaptionExecutionCoordinator(mode: .foregroundOnly)
        let pendingRunStore = FakePendingCaptionRunStore()
        let viewModel = REPACKViewModel(
            engineFactory: fixture.factory,
            captionExecutionCoordinator: executionCoordinator,
            pendingRunStore: pendingRunStore
        )

        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )
        viewModel.selectedImageURL = fixture.imageURL
        viewModel.sampleCount = 2
        viewModel.startProcessing()
        try await waitUntil { viewModel.phase == .output }

        #expect(pendingRunStore.run == nil)
        #expect(!viewModel.hasPendingCaptionRun)
        #expect(executionCoordinator.completions == [true])
        #expect(!executionCoordinator.reportedProgress.isEmpty)
    }

    @Test("Completed runs remain configurable while unchanged results stay available")
    func completedRunRemainsAvailable() async throws {
        let (fixture, viewModel) = try await completedViewModel()
        let initialResult = try #require(viewModel.result)

        #expect(viewModel.phase == .output)
        #expect(viewModel.hasCompletedResult)
        #expect(viewModel.isEngineReady)
        #expect(viewModel.canCaption)

        viewModel.promptChoice = viewModel.promptChoice
        viewModel.customPrompt = viewModel.customPrompt
        viewModel.sampleCount = viewModel.sampleCount
        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )

        #expect(viewModel.phase == .output)
        #expect(viewModel.result == initialResult)

        viewModel.updateThreshold(0.8)
        try await waitUntil { viewModel.result?.threshold == 0.8 }

        #expect(viewModel.phase == .output)
        #expect(viewModel.hasCompletedResult)

        let regeneratedResult = try #require(viewModel.result)
        await viewModel.attachImage(data: Data("not an image".utf8))

        #expect(viewModel.phase == .output)
        #expect(viewModel.result == regeneratedResult)
        #expect(viewModel.hasCompletedResult)
    }

    @Test("Editing completed-run inputs invalidates stale results")
    func completedRunInputChangesInvalidateResult() async throws {
        let (_, promptViewModel) = try await completedViewModel()
        promptViewModel.promptChoice = .product

        #expect(promptViewModel.phase == .ready)
        #expect(promptViewModel.result == nil)
        #expect(!promptViewModel.hasCompletedResult)
        #expect(promptViewModel.canCaption)

        let (_, customPromptViewModel) = try await completedViewModel(
            promptChoice: .custom,
            customPrompt: "Describe the label."
        )
        customPromptViewModel.customPrompt = "Read the label text."

        #expect(customPromptViewModel.phase == .ready)
        #expect(customPromptViewModel.result == nil)
        #expect(!customPromptViewModel.hasCompletedResult)
        #expect(customPromptViewModel.canCaption)

        let (_, sampleCountViewModel) = try await completedViewModel()
        sampleCountViewModel.sampleCount += 1

        #expect(sampleCountViewModel.phase == .ready)
        #expect(sampleCountViewModel.result == nil)
        #expect(!sampleCountViewModel.hasCompletedResult)
        #expect(sampleCountViewModel.canCaption)

        let (_, modelViewModel) = try await completedViewModel()
        let replacementModel = LocalModel(
            url: URL(fileURLWithPath: "/tmp/replacement-model.litertlm"),
            isBundled: false
        )
        await modelViewModel.selectModel(replacementModel)

        #expect(modelViewModel.phase == .ready)
        #expect(modelViewModel.result == nil)
        #expect(!modelViewModel.hasCompletedResult)
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

    @Test("List atomization parses JSON, normalizes statements, and tolerates fences")
    func atomizationListParsing() throws {
        let response = """
            ```json
            [" A red can. ", "", "A red can.", "A logo is visible."]
            ```
            """

        #expect(
            try AtomizationListParser.parse(response)
                == ["A red can.", "A logo is visible."]
        )
    }

    @Test("List atomization extracts arrays without confusing brackets inside strings")
    func atomizationListExtraction() throws {
        let response = """
            Here is the result:
            ["A label includes '[NEW]'.", "A quote says \\"hello\\"."]
            Done.
            """

        #expect(
            try AtomizationListParser.parse(response)
                == ["A label includes '[NEW]'.", "A quote says \"hello\"."]
        )
    }

    @Test("List atomization accepts JSON5 syntax")
    func atomizationListJSON5() throws {
        let response = """
            [
              'There is a can.',
              'The can is red.',
            ]
            """

        #expect(
            try AtomizationListParser.parse(response)
                == ["There is a can.", "The can is red."]
        )
    }

    @Test("List atomization conservatively closes truncated strings and arrays")
    func atomizationListStructuralRepair() throws {
        #expect(
            try AtomizationListParser.parse("[\"There is a can.\", \"The can is red.")
                == ["There is a can.", "The can is red."]
        )
        #expect(
            try AtomizationListParser.parse("[\"There is a can.\",]")
                == ["There is a can."]
        )
    }

    @Test("List atomization rejects malformed and empty responses")
    func atomizationListParsingFailures() {
        #expect(throws: StructuredAtomizationError.invalidListResponse) {
            try AtomizationListParser.parse("A red can.")
        }
        #expect(throws: StructuredAtomizationError.invalidListResponse) {
            try AtomizationListParser.parse("[\"\", \"  \"]")
        }
    }

    @Test("Atomization recovery calls the model only after local repair fails")
    func atomizationRecoveryUsesModelOnce() async throws {
        var localRepairCallCount = 0
        let locallyRecovered = try await AtomizationRecovery.resolve(
            "[\"There is a can.\""
        ) {
            localRepairCallCount += 1
            return "[\"This should not be used.\"]"
        }
        #expect(locallyRecovered.status == .parsed)
        #expect(locallyRecovered.statements == ["There is a can."])
        #expect(localRepairCallCount == 0)

        var modelRepairCallCount = 0
        let modelRecovered = try await AtomizationRecovery.resolve("not json") {
            modelRepairCallCount += 1
            return "[\"There is a bottle.\"]"
        }
        #expect(modelRecovered.status == .parsed)
        #expect(modelRecovered.statements == ["There is a bottle."])
        #expect(modelRepairCallCount == 1)
    }

    @Test("Atomization recovery returns an empty status after one failed model repair")
    func atomizationRecoveryFailureContinues() async throws {
        var modelRepairCallCount = 0
        let result = try await AtomizationRecovery.resolve("not json") {
            modelRepairCallCount += 1
            throw StructuredAtomizationError.invalidListResponse
        }

        #expect(result.status == .unparseable)
        #expect(result.statements.isEmpty)
        #expect(modelRepairCallCount == 1)
    }

    @Test("Atomization recovery propagates cancellation")
    func atomizationRecoveryCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await AtomizationRecovery.resolve("not json") {
                throw CancellationError()
            }
        }
    }

    @Test("Atomization retries a list parsing failure in a fresh attempt")
    func atomizationListRetry() async throws {
        var attempts: [Int] = []
        let result: String = try await AtomizationRetryPolicy.run { attempt in
            attempts.append(attempt)
            if attempt == 0 {
                throw StructuredAtomizationError.invalidListResponse
            }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(attempts == [0, 1])
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

    private func completedViewModel(
        promptChoice: REPACKViewModel.PromptChoice = .describe,
        customPrompt: String = "",
        sampleCount: Int = 2
    ) async throws -> (Fixture, REPACKViewModel) {
        let fixture = Fixture()
        let viewModel = REPACKViewModel(engineFactory: fixture.factory)

        await viewModel.selectModel(
            LocalModel(url: fixture.modelURL, isBundled: false)
        )
        viewModel.selectedImageURL = fixture.imageURL
        viewModel.promptChoice = promptChoice
        viewModel.customPrompt = customPrompt
        viewModel.sampleCount = sampleCount
        viewModel.startProcessing()
        try await waitUntil { viewModel.phase == .output }

        return (fixture, viewModel)
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
    var atomizationStatuses: [String: REPACKAtomizationStatus] = [:]
    var captionSeeds: [Int] = []
    var atomizedCaptions: [String] = []
    var repackagedAtomics: [[String]] = []
    var cancellationCount = 0
    var captionDelay: Duration?
}

@MainActor
private final class FakeInferenceEngine: REPACKInferenceEngine {
    let state: FakeEngineState

    init(state: FakeEngineState) {
        self.state = state
    }

    func generateCaption(image: URL, prompt: String, seed: Int) async throws -> String {
        if let captionDelay = state.captionDelay {
            try await Task.sleep(for: captionDelay)
        }
        state.captionSeeds.append(seed)
        return state.captionResponses[seed] ?? "caption \(seed)"
    }

    func atomize(caption: String) async throws -> REPACKAtomizationResult {
        state.atomizedCaptions.append(caption)
        return REPACKAtomizationResult(
            statements: state.atomicResponses[caption] ?? [caption],
            status: state.atomizationStatuses[caption] ?? .parsed
        )
    }

    func repackage(atomics: [String]) async throws -> String {
        state.repackagedAtomics.append(atomics)
        return atomics.joined(separator: " | ")
    }

    func cancel() async {
        state.cancellationCount += 1
    }
}

@MainActor
private final class FakeCaptionExecutionCoordinator: CaptionExecutionCoordinating {
    let mode: CaptionExecutionMode
    var reportedProgress: [REPACKProgress] = []
    var completions: [Bool] = []
    private var expirationHandler: (@MainActor () -> Void)?
    private var isActive = false

    init(mode: CaptionExecutionMode) {
        self.mode = mode
    }

    func register() {}

    func submit(
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) -> CaptionExecutionMode {
        isActive = true
        expirationHandler = expiration
        if mode == .backgroundProtected {
            start()
        }
        return mode
    }

    func report(_ progress: REPACKProgress) {
        reportedProgress.append(progress)
    }

    func complete(success: Bool) {
        guard isActive else { return }
        isActive = false
        completions.append(success)
        expirationHandler = nil
    }
}

@MainActor
private final class FakePendingCaptionRunStore: PendingCaptionRunStoring {
    var run: PendingCaptionRun?

    func load() -> PendingCaptionRun? {
        run
    }

    func save(_ run: PendingCaptionRun) {
        self.run = run
    }

    func clear() {
        run = nil
    }
}

private actor LifecycleModelDownloadService: ModelDownloadServicing {
    enum Mode: Sendable {
        case waitForCancellation
        case complete(ModelDownloadOutcome)
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func preparePlan(
        for model: DownloadableModel,
        validatesWithoutKeepingFiles: Bool
    ) -> ModelDownloadPlan {
        modelDownloadPlan(validatesWithoutKeepingFiles: validatesWithoutKeepingFiles)
    }

    func execute(
        _ plan: ModelDownloadPlan,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws -> ModelDownloadOutcome {
        if let descriptor = plan.files.first {
            await progressHandler(
                ModelDownloadProgress(
                    requestedModel: plan.requestedModel,
                    currentModel: descriptor.model,
                    fileIndex: 1,
                    fileCount: plan.files.count,
                    completedBytes: 0,
                    totalBytes: plan.totalBytes
                )
            )
        }

        switch mode {
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case .complete(let outcome):
            return outcome
        }
    }

    func isInstalled(_ model: DownloadableModel) -> Bool {
        false
    }

    func cancelCurrentDownload() {}

    func cleanStagingDirectory() {}
}

@MainActor
private final class FakeModelDownloadExecutionCoordinator:
    ModelDownloadExecutionCoordinating {
    func submit(
        transactionID: UUID,
        totalBytes: Int64,
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) -> ModelDownloadExecutionMode {
        start()
        return .backgroundProtected
    }

    func report(_ progress: ModelDownloadProgress) {}

    func complete(success: Bool) {}
}

@MainActor
private final class FakeModelDownloadNotifier: ModelDownloadNotifying {
    func requestAuthorizationIfNeeded() async {}

    func notifyCompletion(message: String) async -> Bool {
        false
    }
}

nonisolated private func modelDownloadPlan(
    validatesWithoutKeepingFiles: Bool = false
) -> ModelDownloadPlan {
    ModelDownloadPlan(
        requestedModel: .e2b,
        files: [
            ModelDownloadFile(
                descriptor: DownloadableModel.e2b.descriptor,
                byteCount: 3
            )
        ],
        dependencyAlreadyInstalled: false,
        validatesWithoutKeepingFiles: validatesWithoutKeepingFiles
    )
}
