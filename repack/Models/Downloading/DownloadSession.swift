import Foundation
import Observation

@MainActor
@Observable
/// Owns the currently active continued-processing task.
final class DownloadSession {
    enum Alert: Identifiable, Equatable {
        case confirmation(DownloadPlan)
        case foregroundFallback(DownloadPlan)
        case message(id: UUID, title: String, message: String)

        var id: String {
            switch self {
            case .confirmation(let plan):
                "confirmation-\(plan.id)"
            case .foregroundFallback(let plan):
                "foreground-\(plan.id)"
            case .message(let id, _, _):
                "message-\(id)"
            }
        }
    }

    var progress: DownloadProgress?
    var isWaiting = false
    var alert: Alert?
    var executionMode: ModelDownloadExecutionMode?
    var task: Task<Void, Never>?

    var isActive: Bool {
        isWaiting || task != nil || progress != nil
    }
}
