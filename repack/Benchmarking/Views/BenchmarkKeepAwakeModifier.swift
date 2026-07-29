#if BENCHMARKING
import SwiftUI

private struct BenchmarkKeepAwakeModifier: ViewModifier {
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

extension View {
    func keepsBenchmarkScreenAwake(
        using manager: any IdleTimerManaging =
            ApplicationIdleTimerManager.shared
    ) -> some View {
        modifier(BenchmarkKeepAwakeModifier(manager: manager))
    }
}
#endif
