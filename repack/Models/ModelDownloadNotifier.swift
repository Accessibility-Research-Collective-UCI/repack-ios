import UserNotifications

nonisolated protocol ModelDownloadNotificationCenter: Sendable {
    func modelDownloadAuthorizationStatus() async -> UNAuthorizationStatus
    func requestModelDownloadAuthorization() async throws -> Bool
    func addModelDownloadNotification(title: String, message: String) async throws
}

extension UNUserNotificationCenter: ModelDownloadNotificationCenter {
    func modelDownloadAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationSettings()
        return settings.authorizationStatus
    }

    func requestModelDownloadAuthorization() async throws -> Bool {
        try await requestAuthorization(options: [.alert, .sound])
    }

    func addModelDownloadNotification(title: String, message: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "model-download-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await add(request)
    }
}

@MainActor
protocol ModelDownloadNotifying: AnyObject {
    func requestAuthorizationIfNeeded() async
    func notifyCompletion(message: String) async -> Bool
}

@MainActor
final class ModelDownloadNotifier: ModelDownloadNotifying {
    static let shared = ModelDownloadNotifier()

    private let center: any ModelDownloadNotificationCenter

    init(center: any ModelDownloadNotificationCenter = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() async {
        let status = await center.modelDownloadAuthorizationStatus()
        guard status == .notDetermined else { return }
        _ = try? await center.requestModelDownloadAuthorization()
    }

    func notifyCompletion(message: String) async -> Bool {
        let status = await center.modelDownloadAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }

        do {
            try await center.addModelDownloadNotification(
                title: String(localized: "REPACK"),
                message: message
            )
            return true
        } catch {
            return false
        }
    }
}
