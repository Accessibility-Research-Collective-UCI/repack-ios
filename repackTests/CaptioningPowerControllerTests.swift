import SwiftUI
import Testing
@testable import repack

@Suite("Captioning Power Controller")
@MainActor
struct CaptioningPowerControllerTests {
    @Test("Active computation prevents idle sleep and dims after the configured delay")
    func activeComputationDimsAndBrightens() async throws {
        let idleTimer = FakeIdleTimerManager()
        let sleeper = ControlledCaptioningSleep()
        let controller = CaptioningPowerController(
            idleTimerManager: idleTimer,
            dimDelay: .seconds(30),
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )

        controller.update(isComputing: true, scenePhase: .active)
        await Task.yield()

        #expect(idleTimer.isPreventingIdleSleep)
        #expect(sleeper.requestedDurations == [.seconds(30)])
        #expect(!controller.isDimmed)

        try sleeper.finishNext()
        await Task.yield()
        #expect(controller.isDimmed)

        controller.brighten()
        await Task.yield()
        #expect(!controller.isDimmed)
        #expect(sleeper.requestedDurations == [.seconds(30), .seconds(30)])

        controller.stop()
        await Task.yield()
        #expect(!idleTimer.isPreventingIdleSleep)
        #expect(!controller.isDimmed)
    }

    @Test("Scene and computation lifecycle release and reacquire idle protection")
    func sceneAndComputationLifecycle() async {
        let idleTimer = FakeIdleTimerManager()
        let sleeper = ControlledCaptioningSleep()
        let controller = CaptioningPowerController(
            idleTimerManager: idleTimer,
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )

        controller.update(isComputing: true, scenePhase: .active)
        await Task.yield()
        #expect(idleTimer.isPreventingIdleSleep)

        controller.update(isComputing: true, scenePhase: .inactive)
        await Task.yield()
        #expect(idleTimer.isPreventingIdleSleep)
        #expect(!controller.isDimmed)

        controller.update(isComputing: true, scenePhase: .background)
        await Task.yield()
        #expect(!idleTimer.isPreventingIdleSleep)

        controller.update(isComputing: true, scenePhase: .active)
        await Task.yield()
        #expect(idleTimer.isPreventingIdleSleep)

        controller.update(isComputing: false, scenePhase: .active)
        await Task.yield()
        #expect(!idleTimer.isPreventingIdleSleep)
        #expect(!controller.isDimmed)
    }

    @Test("Idle timer remains disabled until every scene releases its lease")
    func idleTimerLeasesAreReferenceCounted() {
        var appliedStates: [Bool] = []
        let manager = ApplicationIdleTimerManager { isDisabled in
            appliedStates.append(isDisabled)
        }
        let firstOwner = UUID()
        let secondOwner = UUID()

        manager.setPreventingIdleSleep(true, owner: firstOwner)
        manager.setPreventingIdleSleep(true, owner: secondOwner)
        manager.setPreventingIdleSleep(false, owner: firstOwner)

        #expect(appliedStates == [true])

        manager.setPreventingIdleSleep(false, owner: secondOwner)

        #expect(appliedStates == [true, false])
    }
}

@MainActor
private final class FakeIdleTimerManager: IdleTimerManaging {
    private var owners: Set<UUID> = []

    var isPreventingIdleSleep: Bool {
        !owners.isEmpty
    }

    func setPreventingIdleSleep(_ isPreventing: Bool, owner: UUID) {
        if isPreventing {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }
    }
}

@MainActor
private final class ControlledCaptioningSleep {
    private struct PendingSleep {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var pendingSleeps: [PendingSleep] = []
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestedDurations.append(duration)
                pendingSleeps.append(
                    PendingSleep(id: id, continuation: continuation)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func finishNext() throws {
        let pendingSleep = try #require(pendingSleeps.first)
        pendingSleeps.removeFirst()
        pendingSleep.continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = pendingSleeps.firstIndex(where: { $0.id == id }) else {
            return
        }
        let pendingSleep = pendingSleeps.remove(at: index)
        pendingSleep.continuation.resume(throwing: CancellationError())
    }
}
