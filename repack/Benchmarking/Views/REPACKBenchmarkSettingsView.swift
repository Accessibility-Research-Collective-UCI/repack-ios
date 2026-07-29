#if BENCHMARKING
import SwiftUI

struct REPACKBenchmarkSettingsView: View {
    @Bindable var model: BenchmarkViewModel

    var body: some View {
        Section {
            Stepper(
                "Samples: \(model.sampleCount)",
                value: $model.sampleCount,
                in: 1...10
            )

            Picker("Similarity metric", selection: $model.scoringMetric) {
                ForEach(ScoringMetric.allCases) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("REPACK Settings")
        }
        footer: {
            Text(
                "Uses REPACK’s default threshold for the selected similarity metric."
            )
        }
    }
}
#endif
