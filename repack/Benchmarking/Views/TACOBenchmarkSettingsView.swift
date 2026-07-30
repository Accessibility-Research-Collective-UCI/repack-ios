#if BENCHMARKING
import SwiftUI

struct TACOBenchmarkSettingsView: View {
    @Bindable var model: BenchmarkViewModel

    var body: some View {
        Section("TACO Settings") {
            Stepper(
                "Reformulations: \(model.sampleCount)",
                value: $model.sampleCount,
                in: 1...10
            )
        }
    }
}
#endif
