import BackgroundTasks
import Foundation

nonisolated enum CaptionExecutionMode: Equatable, Sendable {
    case backgroundProtected
    case foregroundOnly
}

@MainActor
protocol CaptionExecutionCoordinating: AnyObject {
    func register()

    func submit(
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) -> CaptionExecutionMode

    func report(_ progress: REPACKProgress)
    func complete(success: Bool)
}

@MainActor
protocol CaptionTaskScheduling: AnyObject {
    var supportsBackgroundGPU: Bool { get }

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any CaptionTaskHandling) -> Void
    ) -> Bool

    func submit(identifier: String, title: String, subtitle: String) throws
    func cancel(identifier: String)
}

@MainActor
protocol CaptionTaskHandling: AnyObject {
    var progress: Progress { get }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

@MainActor
final class CaptionExecutionCoordinator: CaptionExecutionCoordinating {
    static let shared = CaptionExecutionCoordinator()
    static let taskIdentifier = "com.uci.repack-tester.captioning"

    private let scheduler: any CaptionTaskScheduling
    private var didAttemptRegistration = false
    private var isRegistered = false
    private var pendingStart: (@MainActor () -> Void)?
    private var pendingExpiration: (@MainActor () -> Void)?
    private var activeTask: (any CaptionTaskHandling)?
    private var activeTaskCompleted = false
    private var lastProgressUnitCount: Int64 = 0

    init(scheduler: any CaptionTaskScheduling = SystemCaptionTaskScheduler()) {
        self.scheduler = scheduler
    }

    func register() {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true
        isRegistered = scheduler.register(identifier: Self.taskIdentifier) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleLaunch(task)
        }
        captionBackgroundLog(
            isRegistered
                ? "Registered \(Self.taskIdentifier); GPU resource supported: \(scheduler.supportsBackgroundGPU)."
                : "Registration failed for \(Self.taskIdentifier)."
        )
    }

    func submit(
        start: @escaping @MainActor () -> Void,
        expiration: @escaping @MainActor () -> Void
    ) -> CaptionExecutionMode {
        cancelCurrentExecution()

        guard isRegistered else {
            captionBackgroundLog("Using foreground-only captioning because registration is unavailable.")
            return .foregroundOnly
        }
        guard scheduler.supportsBackgroundGPU else {
            captionBackgroundLog(
                "Using foreground-only captioning because BGTaskScheduler does not report GPU support."
            )
            return .foregroundOnly
        }

        pendingStart = start
        pendingExpiration = expiration

        do {
            try scheduler.submit(
                identifier: Self.taskIdentifier,
                title: String(localized: "Captioning Image"),
                subtitle: String(localized: "Preparing captioning models…")
            )
            captionBackgroundLog("Submitted background GPU request with the immediate-fail strategy.")
            return .backgroundProtected
        } catch {
            pendingStart = nil
            pendingExpiration = nil
            captionBackgroundLog(
                "Background GPU request was rejected; using foreground-only captioning. \(error)"
            )
            return .foregroundOnly
        }
    }

    func report(_ progress: REPACKProgress) {
        guard let activeTask, !activeTaskCompleted else { return }

        let unitCount = max(lastProgressUnitCount, progress.continuedTaskUnitCount)
        lastProgressUnitCount = unitCount
        activeTask.progress.completedUnitCount = unitCount
        activeTask.updateTitle(
            String(localized: "Captioning Image"),
            subtitle: progress.continuedTaskSubtitle
        )
    }

    func complete(success: Bool) {
        if let activeTask, !activeTaskCompleted {
            activeTaskCompleted = true
            if success {
                activeTask.progress.completedUnitCount = activeTask.progress.totalUnitCount
                activeTask.updateTitle(
                    String(localized: "Captioning Image"),
                    subtitle: String(localized: "Caption complete.")
                )
            }
            activeTask.setTaskCompleted(success: success)
            captionBackgroundLog("Completed granted background task with success=\(success).")
        } else if pendingStart != nil {
            scheduler.cancel(identifier: Self.taskIdentifier)
            captionBackgroundLog("Cancelled the pending background GPU request.")
        }

        clearExecution()
    }

    private func handleLaunch(_ task: any CaptionTaskHandling) {
        guard let start = pendingStart else {
            task.setTaskCompleted(success: false)
            return
        }

        activeTask = task
        activeTaskCompleted = false
        lastProgressUnitCount = 0
        captionBackgroundLog("Background GPU request was granted; starting inference.")
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0
        task.setExpirationHandler { [weak self] in
            captionBackgroundLog("Background GPU task expired.")
            self?.pendingExpiration?()
        }
        pendingStart = nil
        start()
    }

    private func cancelCurrentExecution() {
        guard activeTask != nil || pendingStart != nil else {
            clearExecution()
            return
        }
        complete(success: false)
    }

    private func clearExecution() {
        pendingStart = nil
        pendingExpiration = nil
        activeTask = nil
        activeTaskCompleted = false
        lastProgressUnitCount = 0
    }
}

private func captionBackgroundLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[REPACK][Background] \(message())")
    #endif
}

@MainActor
private final class SystemCaptionTaskScheduler: CaptionTaskScheduling {
    var supportsBackgroundGPU: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any CaptionTaskHandling) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                launchHandler(SystemCaptionTask(task: task))
            }
        }
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.requiredResources = .gpu
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

@MainActor
private final class SystemCaptionTask: CaptionTaskHandling {
    let progress: Progress

    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
        progress = task.progress
    }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        task.expirationHandler = {
            Task { @MainActor in
                handler()
            }
        }
    }

    func updateTitle(_ title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

private extension REPACKProgress {
    nonisolated var continuedTaskUnitCount: Int64 {
        let fraction: Double
        switch self {
        case .preparingVisionModel:
            fraction = 0
        case .sampling(let completed, let total):
            fraction = 40 * Self.fraction(completed: completed, total: total)
        case .preparingTextModel:
            fraction = 40
        case .atomizing(let completed, let total):
            fraction = 40 + 40 * Self.fraction(completed: completed, total: total)
        case .scoring(let completed, let total):
            fraction = 80 + 15 * Self.fraction(completed: completed, total: total)
        case .repackaging:
            fraction = 95
        }
        return Int64(fraction.rounded(.down))
    }

    nonisolated var continuedTaskSubtitle: String {
        switch self {
        case .preparingVisionModel:
            String(localized: "Preparing the vision model.")
        case .sampling(let completed, let total):
            String(localized: "\(max(total - completed, 0)) of \(total) captions remaining")
        case .preparingTextModel:
            String(localized: "Preparing the text model.")
        case .atomizing(let completed, let total):
            String(localized: "\(max(total - completed, 0)) of \(total) captions remaining")
        case .scoring(let completed, let total):
            String(localized: "\(max(total - completed, 0)) of \(total) statements remaining")
        case .repackaging:
            String(localized: "Repackaging the verified statements.")
        }
    }

    nonisolated static func fraction(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}
