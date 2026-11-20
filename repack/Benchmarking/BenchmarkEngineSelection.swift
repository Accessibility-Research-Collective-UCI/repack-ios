#if BENCHMARKING
import LiteRTLM
import Foundation

nonisolated enum BenchmarkCaptionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case gemma4E2B = "Gemma 4 E2B"
    case gemma4E4B = "Gemma 4 E4B"

    var id: Self { self }

    var downloadableModel: DownloadableModel {
        switch self {
        case .gemma4E2B: .e2b
        case .gemma4E4B: .e4b
        }
    }

    var title: String { rawValue }
}

nonisolated struct BenchmarkEngineSettings: Codable, Equatable, Sendable {
    let model: BenchmarkCaptionModel
    let backend: String
    let visionBackend: String?
    let mtpEnabled: Bool

    init(model: BenchmarkCaptionModel, settings: InferenceEngineSettings) {
        self.model = model
        backend = settings.backend.rawValue
        visionBackend = settings.visionBackend?.rawValue
        mtpEnabled = settings.mtpEnabled
    }
}

nonisolated struct ResolvedBenchmarkModel: Equatable, Sendable {
    let choice: BenchmarkCaptionModel
    let url: URL
}

@MainActor
struct BenchmarkModelInventory {
    let localModels: [LocalModel]
    let devicePolicy: DevicePolicy

    func installedModel(for choice: BenchmarkCaptionModel) -> LocalModel? {
        localModels.first {
            DownloadableModel(modelURL: $0.url) == choice.downloadableModel
        }
    }

    func isSupported(_ choice: BenchmarkCaptionModel) -> Bool {
        choice != .gemma4E4B || devicePolicy.allowsE4B
    }

    func status(for choice: BenchmarkCaptionModel) -> String {
        if !isSupported(choice) {
            return String(localized: "Unavailable on this iPhone")
        }
        return installedModel(for: choice) == nil
            ? String(localized: "Not installed")
            : String(localized: "Installed")
    }

    func resolve(_ choice: BenchmarkCaptionModel) -> ResolvedBenchmarkModel? {
        guard isSupported(choice), let model = installedModel(for: choice) else {
            return nil
        }
        return ResolvedBenchmarkModel(choice: choice, url: model.url)
    }
}
#endif
