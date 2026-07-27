import Foundation

@MainActor
final class BackgroundTaskSession {
    private var identifier: String?
    private var totalUnitCount: Int64 = 0
    private var pendingStart: (@MainActor () -> Void)?
    private var pendingExpiration: (@MainActor () -> Void)?
    private var activeTask: (any ContinuedProcessingTaskHandling)?
    private var isCompleted = false
    private var lastUnitCount: Int64 = 0

    var isActive: Bool {
        activeTask != nil || pendingStart != nil
    }

    func prepare(
        identifier: String,
        totalUnitCount: Int64,
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) {
        self.identifier = identifier
        self.totalUnitCount = totalUnitCount
        pendingStart = start
        pendingExpiration = expiration
    }

    func launch(_ task: any ContinuedProcessingTaskHandling) -> (@MainActor () -> Void)? {
        guard let start = pendingStart else {
            task.setTaskCompleted(success: false)
            return nil
        }

        activeTask = task
        isCompleted = false
        lastUnitCount = 0
        task.progress.totalUnitCount = totalUnitCount
        task.progress.completedUnitCount = 0
        task.setExpirationHandler { [weak self] in
            self?.pendingExpiration?()
        }
        pendingStart = nil
        return start
    }

    func report(unitCount: Int64, title: String, subtitle: String) {
        guard let activeTask, !isCompleted else { return }

        let monotonicUnitCount = max(lastUnitCount, unitCount)
        lastUnitCount = monotonicUnitCount
        activeTask.progress.completedUnitCount = monotonicUnitCount
        activeTask.updateTitle(title, subtitle: subtitle)
    }

    func complete(
        success: Bool,
        title: String,
        successSubtitle: String,
        scheduler: any ContinuedProcessingTaskScheduling
    ) {
        if let activeTask, !isCompleted {
            isCompleted = true
            if success {
                activeTask.progress.completedUnitCount = activeTask.progress.totalUnitCount
                activeTask.updateTitle(title, subtitle: successSubtitle)
            }
            activeTask.setTaskCompleted(success: success)
        } else if let identifier, pendingStart != nil {
            scheduler.cancel(identifier: identifier)
        }
        clear()
    }

    func clear() {
        identifier = nil
        totalUnitCount = 0
        pendingStart = nil
        pendingExpiration = nil
        activeTask = nil
        isCompleted = false
        lastUnitCount = 0
    }
}
