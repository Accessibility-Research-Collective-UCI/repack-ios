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

    func report(_ progress: PipelineProgress)
    func complete(success: Bool)
}

@MainActor
protocol ContinuedProcessingTaskScheduling: AnyObject {
    var supportsBackgroundGPU: Bool { get }

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandling) -> Void
    ) -> Bool

    func submit(identifier: String, title: String, subtitle: String) throws
    func cancel(identifier: String)
}

@MainActor
protocol ContinuedProcessingTaskHandling: AnyObject {
    var progress: Progress { get }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

@MainActor
final class CaptionExecutionCoordinator: CaptionExecutionCoordinating {
    static let shared = CaptionExecutionCoordinator()
    static let taskIdentifier = "com.uci.repack-tester.captioning"

    private let scheduler: any ContinuedProcessingTaskScheduling
    private let session = BackgroundTaskSession()
    private var didAttemptRegistration = false
    private var isRegistered = false

    init(
        scheduler: any ContinuedProcessingTaskScheduling =
            SystemContinuedProcessingTaskScheduler(mode: .captioning)
    ) {
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

        session.prepare(
            identifier: Self.taskIdentifier,
            totalUnitCount: 100,
            start: start,
            expiration: expiration
        )

        do {
            try scheduler.submit(
                identifier: Self.taskIdentifier,
                title: String(localized: "Captioning Image"),
                subtitle: String(localized: "Preparing captioning models…")
            )
            captionBackgroundLog("Submitted background GPU request with the immediate-fail strategy.")
            return .backgroundProtected
        } catch {
            session.clear()
            captionBackgroundLog(
                "Background GPU request was rejected; using foreground-only captioning. \(error)"
            )
            return .foregroundOnly
        }
    }

    func report(_ progress: PipelineProgress) {
        session.report(
            unitCount: progress.continuedTaskUnitCount,
            title: String(localized: "Captioning Image"),
            subtitle: progress.continuedTaskSubtitle
        )
    }

    func complete(success: Bool) {
        session.complete(
            success: success,
            title: String(localized: "Captioning Image"),
            successSubtitle: String(localized: "Caption complete."),
            scheduler: scheduler
        )
        captionBackgroundLog("Completed background task with success=\(success).")
    }

    private func handleLaunch(_ task: any ContinuedProcessingTaskHandling) {
        guard let start = session.launch(task) else { return }
        captionBackgroundLog("Background GPU request was granted; starting inference.")
        start()
    }

    private func cancelCurrentExecution() {
        guard session.isActive else {
            session.clear()
            return
        }
        complete(success: false)
    }
}

private func captionBackgroundLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[REPACK][Background] \(message())")
    #endif
}

nonisolated enum ContinuedProcessingTaskMode: Sendable {
    case captioning
    case modelDownload
}

@MainActor
final class SystemContinuedProcessingTaskScheduler:
    ContinuedProcessingTaskScheduling {
    private let mode: ContinuedProcessingTaskMode

    init(mode: ContinuedProcessingTaskMode) {
        self.mode = mode
    }

    var supportsBackgroundGPU: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandling) -> Void
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
                launchHandler(SystemContinuedProcessingTask(task: task))
            }
        }
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        switch mode {
        case .captioning:
            request.requiredResources = .gpu
            request.strategy = .fail
        case .modelDownload:
            request.strategy = .queue
        }
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

@MainActor
private final class SystemContinuedProcessingTask:
    ContinuedProcessingTaskHandling {
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

private extension PipelineProgress {
    nonisolated var continuedTaskUnitCount: Int64 {
        let fraction: Double
        switch self {
        case .preparingVisionModel:
            fraction = 0
        case .sampling:
            fraction = 40 * (fractionCompleted ?? 1)
        case .preparingTextModel:
            fraction = 40
        case .atomizing:
            fraction = 40 + 40 * (fractionCompleted ?? 1)
        case .scoring:
            fraction = 80 + 15 * (fractionCompleted ?? 1)
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

}
