import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    private enum Route: Hashable {
        case run
    }

    @State private var model = REPACKViewModel()
    @State private var path: [Route] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isModelManagerPresented = false
    @State private var isImporterPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            REPACKHomeView(
                model: model,
                selectedPhotoItem: $selectedPhotoItem,
                showCamera: $isCameraPresented,
                showModelManager: $isModelManagerPresented
            ) {
                model.startProcessing()
                path.append(.run)
            }
            .navigationDestination(for: Route.self) { _ in
                REPACKRunView(model: model) {
                    Task {
                        await model.resetRun()
                        path.removeAll()
                    }
                }
            }
        }
        .task {
            await model.prepareForLaunch()
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
            ModelManagerView(
                model: model,
                importAction: {
                    isModelManagerPresented = false
                    isImporterPresented = true
                }
            )
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.liteRTLMModel]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await model.importModel(from: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
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
    }
}
