import Foundation

nonisolated struct PendingCaptionRun: Codable, Equatable, Sendable {
    let imageFilename: String
    let modelFilename: String
    let promptChoice: String
    let customPrompt: String
    let sampleCount: Int
    let threshold: Double
    let scoringMetric: ScoringMetric

    init(
        imageFilename: String,
        modelFilename: String,
        promptChoice: String,
        customPrompt: String,
        sampleCount: Int,
        threshold: Double,
        scoringMetric: ScoringMetric = .bleu
    ) {
        self.imageFilename = imageFilename
        self.modelFilename = modelFilename
        self.promptChoice = promptChoice
        self.customPrompt = customPrompt
        self.sampleCount = sampleCount
        self.threshold = threshold
        self.scoringMetric = scoringMetric
    }

    var isValid: Bool {
        !imageFilename.isEmpty
            && !modelFilename.isEmpty
            && AppModel.PromptChoice(rawValue: promptChoice) != nil
            && 1...10 ~= sampleCount
            && 0...1 ~= threshold
    }

    private enum CodingKeys: String, CodingKey {
        case imageFilename
        case modelFilename
        case promptChoice
        case customPrompt
        case sampleCount
        case threshold
        case scoringMetric
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageFilename = try container.decode(String.self, forKey: .imageFilename)
        modelFilename = try container.decode(String.self, forKey: .modelFilename)
        promptChoice = try container.decode(String.self, forKey: .promptChoice)
        customPrompt = try container.decode(String.self, forKey: .customPrompt)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        threshold = try container.decode(Double.self, forKey: .threshold)
        scoringMetric = try container.decodeIfPresent(
            ScoringMetric.self,
            forKey: .scoringMetric
        ) ?? .bleu
    }
}

@MainActor
protocol PendingCaptionRunStoring: AnyObject {
    func load() -> PendingCaptionRun?
    func save(_ run: PendingCaptionRun)
    func clear()
}

@MainActor
final class UserDefaultsPendingCaptionRunStore: PendingCaptionRunStoring {
    private static let key = "repack.pendingCaptionRun"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PendingCaptionRun? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        guard let run = try? JSONDecoder().decode(PendingCaptionRun.self, from: data),
              run.isValid else {
            clear()
            return nil
        }
        return run
    }

    func save(_ run: PendingCaptionRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
