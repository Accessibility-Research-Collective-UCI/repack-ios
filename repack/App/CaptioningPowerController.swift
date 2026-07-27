import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
protocol IdleTimerManaging: AnyObject {
    func setPreventingIdleSleep(_ isPreventing: Bool, owner: UUID)
}

@MainActor
final class ApplicationIdleTimerManager: IdleTimerManaging {
    static let shared = ApplicationIdleTimerManager()

    private let applyIdleTimerState: @MainActor (Bool) -> Void
    private var owners: Set<UUID> = []

    init(
        applyIdleTimerState: @escaping @MainActor (Bool) -> Void = { isDisabled in
            UIApplication.shared.isIdleTimerDisabled = isDisabled
        }
    ) {
        self.applyIdleTimerState = applyIdleTimerState
    }

    func setPreventingIdleSleep(_ isPreventing: Bool, owner: UUID) {
        let wasDisabled = !owners.isEmpty

        if isPreventing {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }

        let isDisabled = !owners.isEmpty
        guard isDisabled != wasDisabled else { return }
        applyIdleTimerState(isDisabled)
    }
}

@MainActor
@Observable
final class CaptioningPowerController {
    private(set) var isDimmed = false

    @ObservationIgnored
    private let idleTimerManager: any IdleTimerManaging
    @ObservationIgnored
    private let owner = UUID()
    @ObservationIgnored
    private let dimDelay: Duration
    @ObservationIgnored
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void
    @ObservationIgnored
    private var dimTask: Task<Void, Never>?
    @ObservationIgnored
    private var isComputing = false
    @ObservationIgnored
    private var scenePhase: ScenePhase = .background

    init(
        idleTimerManager: any IdleTimerManaging = ApplicationIdleTimerManager.shared,
        dimDelay: Duration = .seconds(30),
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.idleTimerManager = idleTimerManager
        self.dimDelay = dimDelay
        self.sleep = sleep
    }

    func update(isComputing: Bool, scenePhase: ScenePhase) {
        self.isComputing = isComputing
        self.scenePhase = scenePhase

        idleTimerManager.setPreventingIdleSleep(
            isComputing && scenePhase != .background,
            owner: owner
        )

        guard isComputing, scenePhase == .active else {
            cancelDimming()
            return
        }

        restartDimmingCountdown()
    }

    func brighten() {
        guard isComputing, scenePhase == .active else { return }
        restartDimmingCountdown()
    }

    func stop() {
        isComputing = false
        idleTimerManager.setPreventingIdleSleep(false, owner: owner)
        cancelDimming()
    }

    private func restartDimmingCountdown() {
        dimTask?.cancel()
        isDimmed = false

        dimTask = Task { [weak self, dimDelay, sleep] in
            do {
                try await sleep(dimDelay)
                try Task.checkCancellation()
                guard let self,
                      self.isComputing,
                      self.scenePhase == .active else {
                    return
                }
                self.isDimmed = true
                self.dimTask = nil
            } catch {
                return
            }
        }
    }

    private func cancelDimming() {
        dimTask?.cancel()
        dimTask = nil
        isDimmed = false
    }
}

struct CaptioningDimOverlay: View {
    let brightenAction: () -> Void

    var body: some View {
        Button(action: brightenAction) {
            ZStack {
                Color.black.opacity(0.98)

                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title2)
                    Text("Captioning continues")
                        .font(.headline)
                    Text("Tap to brighten")
                        .font(.caption)
                }
                .foregroundStyle(.gray)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .ignoresSafeArea()
        .accessibilityLabel("Captioning continues. Screen dimmed.")
        .accessibilityHint("Brightens the screen.")
    }
}
