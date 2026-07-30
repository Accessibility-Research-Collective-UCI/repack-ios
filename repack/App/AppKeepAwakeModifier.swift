import Foundation
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

struct AppKeepAwakeModifier: ViewModifier {
    let manager: any IdleTimerManaging
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                manager.setPreventingIdleSleep(true, owner: owner)
            }
            .onDisappear {
                manager.setPreventingIdleSleep(false, owner: owner)
            }
    }
}
