import Foundation

nonisolated enum ModelDownloadExecutionMode: Equatable, Sendable {
    case backgroundProtected
    case foregroundOnly
}

@MainActor
protocol ModelDownloadExecutionCoordinating: AnyObject {
    func submit(
        transactionID: UUID,
        totalBytes: Int64,
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) -> ModelDownloadExecutionMode

    func report(_ progress: DownloadProgress)
    func complete(success: Bool)
}

@MainActor
/// Protects long model transfers with continued-processing tasks when possible.
final class ModelDownloadExecutionCoordinator: ModelDownloadExecutionCoordinating {
    static let shared = ModelDownloadExecutionCoordinator()
    static let taskIdentifierPrefix = "com.uci.repack-tester.model-download."

    private let scheduler: any ContinuedProcessingTaskScheduling
    private let session = BackgroundTaskSession()

    init(
        scheduler: any ContinuedProcessingTaskScheduling =
            SystemContinuedProcessingTaskScheduler(mode: .modelDownload)
    ) {
        self.scheduler = scheduler
    }

    func submit(
        transactionID: UUID,
        totalBytes: Int64,
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) -> ModelDownloadExecutionMode {
        complete(success: false)

        let identifier =
            Self.taskIdentifierPrefix + transactionID.uuidString.lowercased()
        guard scheduler.register(
            identifier: identifier,
            launchHandler: { [weak self] task in
                self?.handleLaunch(task)
            }
        ) else {
            modelDownloadBackgroundLog(
                "Registration failed for \(identifier); foreground-only download required."
            )
            return .foregroundOnly
        }

        session.prepare(
            identifier: identifier,
            totalUnitCount: totalBytes,
            start: start,
            expiration: expiration
        )

        do {
            try scheduler.submit(
                identifier: identifier,
                title: String(localized: "Downloading Models"),
                subtitle: String(localized: "Waiting to start…")
            )
            modelDownloadBackgroundLog("Submitted continued download task \(identifier).")
            return .backgroundProtected
        } catch {
            modelDownloadBackgroundLog(
                "Continued download task was rejected; foreground-only download required. \(error)"
            )
            session.clear()
            return .foregroundOnly
        }
    }

    func report(_ progress: DownloadProgress) {
        session.report(
            unitCount: progress.completedBytes,
            title: String(localized: "Downloading Models"),
            subtitle: String(
                localized:
                    "\(progress.currentFileDescription): \(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))"
            )
        )
    }

    func complete(success: Bool) {
        session.complete(
            success: success,
            title: String(localized: "Downloading Models"),
            successSubtitle: String(localized: "Download complete."),
            scheduler: scheduler
        )
    }

    private func handleLaunch(_ task: any ContinuedProcessingTaskHandling) {
        guard let start = session.launch(task) else { return }
        start()
    }
}

private func modelDownloadBackgroundLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        print("[REPACK][Model Download] \(message())")
    #endif
}
