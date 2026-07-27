import Foundation

nonisolated struct PendingCaptionRun: Codable, Equatable, Sendable {
    let imageFilename: String
    let modelFilename: String
    let promptChoice: String
    let customPrompt: String
    let sampleCount: Int
    let threshold: Double

    var isValid: Bool {
        !imageFilename.isEmpty
            && !modelFilename.isEmpty
            && REPACKViewModel.PromptChoice(rawValue: promptChoice) != nil
            && 1...10 ~= sampleCount
            && 0...1 ~= threshold
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
