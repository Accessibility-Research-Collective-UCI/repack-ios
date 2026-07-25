import Foundation
import Testing
@testable import repack

@Suite("Caption Execution", .serialized)
@MainActor
struct CaptionExecutionTests {
    @Test("Supported GPU work starts under a continued task and reports monotonic progress")
    func protectedExecutionAndProgress() throws {
        let scheduler = FakeCaptionTaskScheduler()
        let coordinator = CaptionExecutionCoordinator(scheduler: scheduler)
        coordinator.register()
        var startCount = 0

        let mode = coordinator.submit(
            start: { startCount += 1 },
            expiration: {}
        )

        #expect(mode == .backgroundProtected)
        #expect(startCount == 1)
        #expect(scheduler.submissions.count == 1)
        let task = try #require(scheduler.lastTask)

        let updates: [REPACKProgress] = [
            .preparingVisionModel,
            .sampling(completed: 3, total: 6),
            .preparingTextModel,
            .atomizing(completed: 3, total: 6),
            .scoring(completed: 1, total: 4),
            .repackaging
        ]
        var completedUnitCounts: [Int64] = []
        for update in updates {
            coordinator.report(update)
            completedUnitCounts.append(task.progress.completedUnitCount)
        }

        #expect(completedUnitCounts == completedUnitCounts.sorted())
        #expect(completedUnitCounts == [0, 20, 40, 60, 83, 95])

        coordinator.complete(success: true)
        coordinator.complete(success: false)

        #expect(task.progress.completedUnitCount == 100)
        #expect(task.completions == [true])
        #expect(task.titleUpdates.last?.subtitle == "Caption complete.")
    }

    @Test("Unsupported GPU and submission failure use foreground-only execution")
    func foregroundFallbacks() {
        let unregisteredScheduler = FakeCaptionTaskScheduler()
        unregisteredScheduler.registrationSucceeds = false
        let unregisteredCoordinator = CaptionExecutionCoordinator(
            scheduler: unregisteredScheduler
        )
        unregisteredCoordinator.register()

        let unregisteredMode = unregisteredCoordinator.submit(
            start: {},
            expiration: {}
        )

        #expect(unregisteredMode == .foregroundOnly)
        #expect(unregisteredScheduler.submissions.isEmpty)

        let unsupportedScheduler = FakeCaptionTaskScheduler()
        unsupportedScheduler.supportsBackgroundGPU = false
        let unsupportedCoordinator = CaptionExecutionCoordinator(
            scheduler: unsupportedScheduler
        )
        unsupportedCoordinator.register()
        var unsupportedStarts = 0

        let unsupportedMode = unsupportedCoordinator.submit(
            start: { unsupportedStarts += 1 },
            expiration: {}
        )

        #expect(unsupportedMode == .foregroundOnly)
        #expect(unsupportedStarts == 0)
        #expect(unsupportedScheduler.submissions.isEmpty)

        let failingScheduler = FakeCaptionTaskScheduler()
        failingScheduler.submissionError = FakeSchedulerError.ineligible
        let failingCoordinator = CaptionExecutionCoordinator(scheduler: failingScheduler)
        failingCoordinator.register()
        var failedStarts = 0

        let failingMode = failingCoordinator.submit(
            start: { failedStarts += 1 },
            expiration: {}
        )

        #expect(failingMode == .foregroundOnly)
        #expect(failedStarts == 0)
        #expect(failingScheduler.submissions.count == 1)
    }

    @Test("Expiration and cancellation complete a task no more than once")
    func expirationAndCompletion() throws {
        let scheduler = FakeCaptionTaskScheduler()
        let coordinator = CaptionExecutionCoordinator(scheduler: scheduler)
        coordinator.register()
        var expirationCount = 0

        _ = coordinator.submit(
            start: {},
            expiration: { expirationCount += 1 }
        )
        let task = try #require(scheduler.lastTask)
        task.expire()

        #expect(expirationCount == 1)

        coordinator.complete(success: false)
        coordinator.complete(success: false)

        #expect(task.completions == [false])
    }

    @Test("Cancelling before launch removes the pending scheduler request")
    func pendingCancellation() {
        let scheduler = FakeCaptionTaskScheduler()
        scheduler.launchImmediately = false
        let coordinator = CaptionExecutionCoordinator(scheduler: scheduler)
        coordinator.register()

        let mode = coordinator.submit(start: {}, expiration: {})
        coordinator.complete(success: false)

        #expect(mode == .backgroundProtected)
        #expect(scheduler.cancelledIdentifiers == [CaptionExecutionCoordinator.taskIdentifier])
    }

    @Test("Pending run metadata round trips and rejects corrupt data")
    func pendingRunPersistence() throws {
        let suiteName = "CaptionExecutionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPendingCaptionRunStore(defaults: defaults)
        let run = PendingCaptionRun(
            imageFilename: "image.jpg",
            modelFilename: "model.litertlm",
            promptChoice: "custom",
            customPrompt: "Describe the package.",
            sampleCount: 4,
            threshold: 0.7
        )

        store.save(run)
        #expect(store.load() == run)

        defaults.set(Data("not JSON".utf8), forKey: "repack.pendingCaptionRun")
        #expect(store.load() == nil)
        #expect(defaults.data(forKey: "repack.pendingCaptionRun") == nil)
    }
}

@MainActor
private final class FakeCaptionTaskScheduler: CaptionTaskScheduling {
    struct Submission: Equatable {
        let identifier: String
        let title: String
        let subtitle: String
    }

    var supportsBackgroundGPU = true
    var registrationSucceeds = true
    var launchImmediately = true
    var submissionError: (any Error)?
    var submissions: [Submission] = []
    var cancelledIdentifiers: [String] = []
    private(set) var lastTask: FakeCaptionTask?
    private var launchHandler: (@MainActor (any CaptionTaskHandling) -> Void)?

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any CaptionTaskHandling) -> Void
    ) -> Bool {
        self.launchHandler = launchHandler
        return registrationSucceeds
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        submissions.append(
            Submission(identifier: identifier, title: title, subtitle: subtitle)
        )
        if let submissionError {
            throw submissionError
        }
        guard launchImmediately else { return }

        let task = FakeCaptionTask()
        lastTask = task
        launchHandler?(task)
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }
}

@MainActor
private final class FakeCaptionTask: CaptionTaskHandling {
    struct TitleUpdate: Equatable {
        let title: String
        let subtitle: String
    }

    let progress = Progress(totalUnitCount: 0)
    var completions: [Bool] = []
    var titleUpdates: [TitleUpdate] = []
    private var expirationHandler: (@MainActor () -> Void)?

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        expirationHandler = handler
    }

    func updateTitle(_ title: String, subtitle: String) {
        titleUpdates.append(TitleUpdate(title: title, subtitle: subtitle))
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func expire() {
        expirationHandler?()
    }
}

nonisolated private enum FakeSchedulerError: Error {
    case ineligible
}
