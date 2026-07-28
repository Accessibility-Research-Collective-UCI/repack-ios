import Accessibility
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case missingModel
        case loadingModel
        case downloading(name: String, progress: Double)
        case ready
        case processing
        case interrupted(String)
        case output
        case failed(String)
    }
    enum PromptChoice: String, CaseIterable, Identifiable {
        case product
        case describe
        case custom

        var id: Self { self }

        var title: String {
            switch self {
            case .product:
                String(localized: "Product")
            case .describe:
                String(localized: "Describe")
            case .custom:
                String(localized: "Custom")
            }
        }
    }
    var phase: Phase = .missingModel
    var localModels: [LocalModel] = []
    var modelStorageItems: [StorageItem] = []
    var modelURL: URL?
    let downloadSession = DownloadSession()
    var selectedImageURL: URL?
    var promptChoice: PromptChoice = .describe {
        didSet {
            guard promptChoice != oldValue else { return }
            invalidateCompletedResult()
        }
    }
    var customPrompt = "" {
        didSet {
            guard customPrompt != oldValue else { return }
            invalidateCompletedResult()
        }
    }
    var sampleCount = 5 {
        didSet {
            guard sampleCount != oldValue else { return }
            invalidateCompletedResult()
        }
    }
    var scoringMetric: ScoringMetric = .bleu {
        didSet {
            guard scoringMetric != oldValue else { return }
            threshold = scoringMetric.threshold.defaultValue
            invalidateCompletedResult()
        }
    }
    var threshold = 0.5
    var progress: PipelineProgress?
    var result: CaptionResult?
    var isRegenerating = false
    var errorMessage: String?
    var hasPendingCaptionRun = false
    let modelManager: ModelLibrary
    let imageStore: ImageStore
    let engineFactory: any EngineFactory
    let devicePolicy: DevicePolicy
    let captionExecutionCoordinator: any CaptionExecutionCoordinating
    let modelDownloadExecutionCoordinator: any ModelDownloadExecutionCoordinating
    let modelDownloadNotifier: any ModelDownloadNotifying
    let pendingRunStore: any PendingCaptionRunStoring
    let clock = ContinuousClock()
    var pipeline: REPACKPipeline?
    var processTask: Task<Void, Never>?
    var thresholdTask: Task<Void, Never>?
    var ownedImageURLs: Set<URL> = []
    var processStartedAt: ContinuousClock.Instant?
    var completedElapsed: Duration?
    var thresholdRequestID = UUID()
    var currentRunID: UUID?
    var executionMode: CaptionExecutionMode?
    var isLoadingPipeline = false

    init(
        modelManager: ModelLibrary? = nil,
        imageStore: ImageStore = .shared,
        engineFactory: (any EngineFactory)? = nil,
        devicePolicy: DevicePolicy = .current,
        captionExecutionCoordinator: any CaptionExecutionCoordinating =
            CaptionExecutionCoordinator.shared,
        modelDownloadExecutionCoordinator: any ModelDownloadExecutionCoordinating =
            ModelDownloadExecutionCoordinator.shared,
        modelDownloadNotifier: any ModelDownloadNotifying =
            ModelDownloadNotifier.shared,
        pendingRunStore: any PendingCaptionRunStoring =
            UserDefaultsPendingCaptionRunStore()
    ) {
        self.modelManager = modelManager ?? ModelLibrary()
        self.imageStore = imageStore
        self.engineFactory = engineFactory ?? LiteRTEngineFactory.shared
        self.devicePolicy = devicePolicy
        self.captionExecutionCoordinator = captionExecutionCoordinator
        self.modelDownloadExecutionCoordinator = modelDownloadExecutionCoordinator
        self.modelDownloadNotifier = modelDownloadNotifier
        self.pendingRunStore = pendingRunStore
    }
    var selectedModelName: String {
        guard let modelURL else {
            return String(localized: "Select which model to caption with")
        }
        return DownloadableModel.displayName(for: modelURL)
    }

    var verificationModelName: String {
        guard let modelURL,
              let processingModelURL = ModelLibrary.processingModelURL(
                for: modelURL,
                availableModels: localModels
              ) else {
            return selectedModelName
        }
        return DownloadableModel.displayName(for: processingModelURL)
    }

    var promptDisplayText: String {
        switch promptChoice {
        case .product:
            String(localized: "Product preset")
        case .describe:
            String(localized: "Describe preset")
        case .custom:
            samplePrompt.resolvedText
        }
    }

    var selectableLocalModels: [LocalModel] {
        localModels.filter { supportsModel(at: $0.url) }
    }

    func supportsModel(at url: URL) -> Bool {
        !ModelLibrary.isE4B(url) || devicePolicy.allowsE4B
    }

    func supportsDownload(_ model: DownloadableModel) -> Bool {
        model != .e4b || devicePolicy.allowsE4B
    }

    func isModelInstalled(_ model: DownloadableModel) -> Bool {
        modelManager.isInstalled(model)
    }

    var defaultScoringMetric: ScoringMetric {
        Self.defaultScoringMetric(
            embeddingModelInstalled: isModelInstalled(.embeddingGemma)
        )
    }

    nonisolated static func defaultScoringMetric(
        embeddingModelInstalled: Bool
    ) -> ScoringMetric {
        embeddingModelInstalled ? .semanticSimilarity : .bleu
    }

    var isBusy: Bool {
        switch phase {
        case .loadingModel, .downloading, .processing:
            true
        case .missingModel, .ready, .interrupted, .output, .failed:
            false
        }
    }

    var isModelDownloadActive: Bool {
        downloadSession.isActive
    }

    var modelDownloadProgress: DownloadProgress? {
        get { downloadSession.progress }
        set { downloadSession.progress = newValue }
    }

    var isModelDownloadWaiting: Bool {
        get { downloadSession.isWaiting }
        set { downloadSession.isWaiting = newValue }
    }

    var modelDownloadAlert: DownloadSession.Alert? {
        get { downloadSession.alert }
        set { downloadSession.alert = newValue }
    }

    var modelDownloadExecutionMode: ModelDownloadExecutionMode? {
        get { downloadSession.executionMode }
        set { downloadSession.executionMode = newValue }
    }

    var modelDownloadTask: Task<Void, Never>? {
        get { downloadSession.task }
        set { downloadSession.task = newValue }
    }

    var isEngineReady: Bool {
        if hasCompletedResult {
            return true
        }
        guard pipeline != nil else { return false }
        return switch phase {
        case .ready, .interrupted, .failed:
            true
        case .missingModel, .loadingModel, .downloading, .processing, .output:
            false
        }
    }

    var hasCompletedResult: Bool {
        phase == .output && result != nil
    }

    var canCaption: Bool {
        isEngineReady
            && selectedImageURL != nil
            && !samplePrompt.resolvedText.isEmpty
            && (scoringMetric == .bleu || semanticScoringAvailable)
    }

    var semanticScoringAvailable: Bool {
        EmbeddingModelResources.available() != nil
    }

    var scoringModelName: String {
        switch scoringMetric {
        case .bleu:
            String(localized: "Lexical Similarity")
        case .semanticSimilarity:
            EmbeddingModelResources.displayName
        }
    }

    var shouldOfferRestart: Bool {
        guard phase != .processing else { return false }
        if hasPendingCaptionRun { return true }
        if case .interrupted = phase { return true }
        return false
    }

    var samplePrompt: CaptionPrompt {
        switch promptChoice {
        case .product:
            .product
        case .describe:
            .describe
        case .custom:
            .custom(customPrompt)
        }
    }

    var elapsed: Duration? {
        if let processStartedAt {
            processStartedAt.duration(to: clock.now)
        } else {
            completedElapsed
        }
    }
}
