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

    func report(_ progress: ModelDownloadProgress)
    func complete(success: Bool)
}

typealias ModelDownloadTaskScheduling = ContinuedProcessingTaskScheduling
typealias ModelDownloadTaskHandling = ContinuedProcessingTaskHandling

@MainActor
final class ModelDownloadExecutionCoordinator: ModelDownloadExecutionCoordinating {
    static let shared = ModelDownloadExecutionCoordinator()
    static let taskIdentifierPrefix = "com.uci.repack-tester.model-download."

    private let scheduler: any ModelDownloadTaskScheduling
    private var taskIdentifier: String?
    private var totalBytes: Int64 = 0
    private var pendingStart: (@MainActor () -> Void)?
    private var pendingExpiration: (@MainActor () -> Void)?
    private var activeTask: (any ModelDownloadTaskHandling)?
    private var activeTaskCompleted = false
    private var lastCompletedBytes: Int64 = 0

    init(
        scheduler: any ModelDownloadTaskScheduling =
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

        self.taskIdentifier = identifier
        self.totalBytes = totalBytes
        pendingStart = start
        pendingExpiration = expiration

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
            clearExecution()
            return .foregroundOnly
        }
    }

    func report(_ progress: ModelDownloadProgress) {
        guard let activeTask, !activeTaskCompleted else { return }

        let completedBytes = max(lastCompletedBytes, progress.completedBytes)
        lastCompletedBytes = completedBytes
        activeTask.progress.completedUnitCount = completedBytes
        activeTask.updateTitle(
            String(localized: "Downloading Models"),
            subtitle: String(
                localized:
                    "\(progress.currentFileDescription): \(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))"
            )
        )
    }

    func complete(success: Bool) {
        if let activeTask, !activeTaskCompleted {
            activeTaskCompleted = true
            if success {
                activeTask.progress.completedUnitCount = activeTask.progress.totalUnitCount
                activeTask.updateTitle(
                    String(localized: "Downloading Models"),
                    subtitle: String(localized: "Download complete.")
                )
            }
            activeTask.setTaskCompleted(success: success)
        } else if let taskIdentifier, pendingStart != nil {
            scheduler.cancel(identifier: taskIdentifier)
        }

        clearExecution()
    }

    private func handleLaunch(_ task: any ModelDownloadTaskHandling) {
        guard let start = pendingStart else {
            task.setTaskCompleted(success: false)
            return
        }

        activeTask = task
        activeTaskCompleted = false
        lastCompletedBytes = 0
        task.progress.totalUnitCount = totalBytes
        task.progress.completedUnitCount = 0
        task.setExpirationHandler { [weak self] in
            modelDownloadBackgroundLog("Continued model download expired or was cancelled.")
            self?.pendingExpiration?()
        }
        pendingStart = nil
        start()
    }

    private func clearExecution() {
        taskIdentifier = nil
        totalBytes = 0
        pendingStart = nil
        pendingExpiration = nil
        activeTask = nil
        activeTaskCompleted = false
        lastCompletedBytes = 0
    }
}

private func modelDownloadBackgroundLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        print("[REPACK][Model Download] \(message())")
    #endif
}
