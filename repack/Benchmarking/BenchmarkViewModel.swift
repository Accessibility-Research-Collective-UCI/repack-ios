#if BENCHMARKING
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class BenchmarkViewModel {
    private static let cooldownSeconds = 15

    enum Phase: Equatable {
        case setup
        case running
        case cooldown
        case result
    }

    var algorithm: BenchmarkAlgorithm = .repack
    var visionModel: BenchmarkCaptionModel = .gemma4E2B
    var textModel: BenchmarkCaptionModel = .gemma4E2B
    var sampleCount = REPACKBenchmarkConfiguration.default.sampleCount
    var scoringMetric = REPACKBenchmarkConfiguration.default.scoringMetric
    var promptType: BenchmarkPromptType = .describe
    var customPrompt = ""

    private(set) var phase = Phase.setup
    private(set) var completedImageCount = 0
    private(set) var totalImageCount = 25
    private(set) var currentFile: String?
    private(set) var currentProgress: BenchmarkAlgorithmProgress?
    private(set) var completedActiveDuration = Duration.zero
    private(set) var activeImageStartedAt: Date?
    private(set) var cooldownRemaining = BenchmarkViewModel.cooldownSeconds
    private(set) var output: BenchmarkOutput?
    private(set) var localModels: [LocalModel]

    @ObservationIgnored private let devicePolicy: DevicePolicy
    @ObservationIgnored private let runner: BenchmarkRunner
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        localModels: [LocalModel],
        devicePolicy: DevicePolicy = .current,
        runner: BenchmarkRunner? = nil
    ) {
        self.localModels = localModels
        self.devicePolicy = devicePolicy
        self.runner = runner ?? BenchmarkRunner(
            executorFactory: DefaultBenchmarkAlgorithmExecutorFactory(
                devicePolicy: devicePolicy
            )
        )
    }

    deinit {
        task?.cancel()
    }

    var algorithmStages: [BenchmarkStage] {
        algorithm.stages
    }

    var averageDuration: Duration? {
        guard completedImageCount > 0 else { return nil }
        return completedActiveDuration / completedImageCount
    }

    var estimatedTimeRemaining: Duration? {
        guard let averageDuration else { return nil }
        return Self.estimatedTimeRemaining(
            averageDuration: averageDuration,
            completedImageCount: completedImageCount,
            totalImageCount: totalImageCount,
            cooldownSeconds: Self.cooldownSeconds
        )
    }

    static func estimatedTimeRemaining(
        averageDuration: Duration,
        completedImageCount: Int,
        totalImageCount: Int,
        cooldownSeconds: Int
    ) -> Duration {
        let remainingImages = max(totalImageCount - completedImageCount, 0)
        let remainingCooldowns = max(remainingImages - 1, 0)
        return averageDuration * remainingImages
            + .seconds(cooldownSeconds * remainingCooldowns)
    }

    var canStart: Bool {
        task == nil && preflightMessages.isEmpty
    }

    var preflightMessages: [String] {
        var messages: [String] = []
        let inventory = modelInventory

        if !inventory.isSupported(visionModel) {
            messages.append(
                String(localized: "\(visionModel.title) cannot be used on this iPhone.")
            )
        } else if inventory.installedModel(for: visionModel) == nil {
            messages.append(
                String(localized: "Install \(visionModel.title) for the vision engine.")
            )
        }

        if !inventory.isSupported(textModel) {
            messages.append(
                String(localized: "\(textModel.title) cannot be used on this iPhone.")
            )
        } else if inventory.installedModel(for: textModel) == nil {
            messages.append(
                String(localized: "Install \(textModel.title) for the text engine.")
            )
        }

        if scoringMetric == .semanticSimilarity,
           EmbeddingModelResources.available() == nil {
            messages.append(
                String(localized: "Install Embedding Gemma for semantic similarity.")
            )
        }

        if resolvedPrompt.isEmpty {
            messages.append(String(localized: "Enter a custom captioning prompt."))
        }
        return messages
    }

    func modelStatus(_ choice: BenchmarkCaptionModel) -> String {
        modelInventory.status(for: choice)
    }

    func elapsed(at date: Date) -> Duration {
        guard let activeImageStartedAt else {
            return completedActiveDuration
        }
        return completedActiveDuration
            + .seconds(max(date.timeIntervalSince(activeImageStartedAt), 0))
    }

    func updateLocalModels(_ models: [LocalModel]) {
        localModels = models
    }

    func start() {
        guard task == nil else { return }
        guard let request = makeRequest() else { return }

        phase = .running
        completedImageCount = 0
        totalImageCount = 25
        currentFile = nil
        currentProgress = nil
        completedActiveDuration = .zero
        activeImageStartedAt = nil
        output = nil

        task = Task { [weak self, runner] in
            let output = await runner.run(request: request) { [weak self] event in
                self?.handle(event)
            }
            guard let self else { return }
            self.output = output
            self.activeImageStartedAt = nil
            self.phase = .result
            self.task = nil
        }
    }

    func cancel() {
        interrupt(
            BenchmarkFailure(
                kind: .cancelled,
                message: String(localized: "Benchmark stopped by the user."),
                file: currentFile
            )
        )
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard scenePhase == .background,
              phase == .running || phase == .cooldown else {
            return
        }
        interrupt(
            BenchmarkFailure(
                kind: .backgrounded,
                message: String(
                    localized: "Benchmark interrupted because the app entered the background."
                ),
                file: currentFile
            )
        )
    }

    func reset() {
        guard task == nil else { return }
        phase = .setup
        output = nil
        currentFile = nil
        currentProgress = nil
    }

    private var modelInventory: BenchmarkModelInventory {
        BenchmarkModelInventory(
            localModels: localModels,
            devicePolicy: devicePolicy
        )
    }

    private var resolvedPrompt: String {
        promptType.prompt(customText: customPrompt).resolvedText
    }

    private func makeRequest() -> BenchmarkRunRequest? {
        let inventory = modelInventory
        guard preflightMessages.isEmpty,
              let resolvedVisionModel = inventory.resolve(visionModel),
              let resolvedTextModel = inventory.resolve(textModel) else {
            return nil
        }
        return BenchmarkRunRequest(
            algorithm: algorithm,
            visionModel: resolvedVisionModel,
            textModel: resolvedTextModel,
            algorithmConfiguration: .repack(
                REPACKBenchmarkConfiguration(
                    sampleCount: sampleCount,
                    scoringMetric: scoringMetric
                )
            ),
            prompt: BenchmarkPromptSettings(
                type: promptType,
                text: resolvedPrompt
            ),
            cooldownSeconds: Self.cooldownSeconds
        )
    }

    private func handle(_ event: BenchmarkRunnerEvent) {
        switch event {
        case .imageStarted(let index, let total, let file, let start):
            phase = .running
            completedImageCount = index
            totalImageCount = total
            currentFile = file
            currentProgress = nil
            activeImageStartedAt = start
        case .algorithmProgress(let progress):
            currentProgress = progress
        case .imageCompleted(let index, let total, let timing):
            completedImageCount = index
            totalImageCount = total
            completedActiveDuration += .seconds(timing.totalTime)
            activeImageStartedAt = nil
            currentProgress = nil
        case .cooldown(let secondsRemaining):
            phase = .cooldown
            cooldownRemaining = secondsRemaining
            activeImageStartedAt = nil
        }
    }

    private func interrupt(_ failure: BenchmarkFailure) {
        guard let task else { return }
        runner.setInterruption(failure)
        task.cancel()
        Task { [runner] in
            await runner.cancelCurrentExecution()
        }
    }
}
#endif
