#if BENCHMARKING
import SwiftUI

struct BenchmarkRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: BenchmarkViewModel

    let localModels: [LocalModel]
    let showModelManager: () -> Void

    init(
        localModels: [LocalModel],
        showModelManager: @escaping () -> Void
    ) {
        self.localModels = localModels
        self.showModelManager = showModelManager
        _model = State(
            initialValue: BenchmarkViewModel(localModels: localModels)
        )
    }

    var body: some View {
        Group {
            switch model.phase {
            case .setup:
                BenchmarkSetupView(
                    model: model,
                    showModelManager: showModelManager
                )
            case .running, .cooldown:
                BenchmarkRunningView(model: model)
            case .result:
                BenchmarkOutputView(model: model)
            }
        }
        .navigationTitle("Benchmark")
        .onAppear {
            model.updateLocalModels(localModels)
        }
        .onChange(of: localModels) { _, models in
            model.updateLocalModels(models)
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}
#endif
