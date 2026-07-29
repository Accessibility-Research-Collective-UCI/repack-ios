import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    private enum Route: Hashable {
        case run
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var powerController = CaptioningPowerController()
    @State private var path: [Route] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isModelManagerPresented = false

    var body: some View {
        rootContent
            .overlay {
                if powerController.isDimmed {
                    CaptioningDimOverlay {
                        powerController.brighten()
                    }
                }
            }
            .task {
                updateCaptioningPower()
                await model.prepareForLaunch()
                await model.handleScenePhase(scenePhase)
            }
            .onChange(of: model.phase) {
                updateCaptioningPower()
            }
            .onChange(of: scenePhase) { _, newPhase in
                updateCaptioningPower(scenePhase: newPhase)
                Task {
                    await model.handleScenePhase(newPhase)
                }
            }
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    defer { selectedPhotoItem = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            model.errorMessage = String(localized: "The selected photo could not be read.")
                            return
                        }
                        await model.attachImage(data: data)
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: $isCameraPresented) {
                CameraImagePicker { image in
                    Task {
                        await model.attachImage(image: image)
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $isModelManagerPresented) {
                ModelLibraryView(model: model)
            }
            .alert(
                "REPACK",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK") {
                    model.errorMessage = nil
                }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onDisappear {
                powerController.stop()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if BENCHMARKING
        BenchmarkTabContainer {
            repackNavigation
        } benchmark: {
            NavigationStack {
                BenchmarkRootView(
                    localModels: model.selectableLocalModels,
                    showModelManager: {
                        isModelManagerPresented = true
                    }
                )
            }
        }
        #else
        repackNavigation
        #endif
    }

    private var repackNavigation: some View {
        NavigationStack(path: $path) {
            HomeView(
                model: model,
                selectedPhotoItem: $selectedPhotoItem,
                showCamera: $isCameraPresented,
                showModelManager: $isModelManagerPresented,
                captionAction: {
                    model.startProcessing()
                    path.append(.run)
                },
                resultsAction: {
                    path.append(.run)
                }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .run:
                    RunView(
                        model: model,
                        restartAction: { model.startProcessing() },
                        cancelAction: {
                            Task {
                                await model.cancelProcessing()
                                path.removeAll()
                            }
                        },
                        resetAction: {
                            Task {
                                await model.resetRun()
                                path.removeAll()
                            }
                        }
                    )
                }
            }
        }
    }

    private func updateCaptioningPower(scenePhase: ScenePhase? = nil) {
        powerController.update(
            isComputing: model.phase == .processing,
            scenePhase: scenePhase ?? self.scenePhase
        )
    }
}
