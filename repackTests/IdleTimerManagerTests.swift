import Foundation
import Testing
@testable import repack

@Suite("Idle Timer Manager")
@MainActor
struct IdleTimerManagerTests {
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
