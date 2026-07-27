import PhotosUI
import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showCamera: Bool
    @Binding var showModelManager: Bool
    let captionAction: () -> Void
    let resultsAction: () -> Void
    @State private var isModelSelectionPresented = false

    var body: some View {
        Form {
            if model.shouldOfferRestart {
                Section("Interrupted Caption") {
                    Label(
                        "The previous caption did not finish. Your image and settings were restored.",
                        systemImage: "arrow.counterclockwise.circle.fill"
                    )
                }
            }

            HomeModelSection(
                model: model,
                showSelection: $isModelSelectionPresented,
                showLibrary: $showModelManager
            )
            HomeImageSection(
                model: model,
                selectedPhotoItem: $selectedPhotoItem,
                showCamera: $showCamera
            )
            CaptionSettings(model: model)
            captionButton
        }
        .navigationTitle("📦 REPACK")
        .sheet(isPresented: $isModelSelectionPresented) {
            ModelSelectionView(model: model)
        }
    }

    private var captionButton: some View {
        Button(action: model.hasCompletedResult ? resultsAction : captionAction) {
            Text(captionButtonTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.hasCompletedResult && !model.canCaption)
        .listRowInsets(.init(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var captionButtonTitle: LocalizedStringKey {
        if model.hasCompletedResult {
            "View Results"
        } else if model.shouldOfferRestart {
            "Restart Captioning"
        } else {
            "Caption Image"
        }
    }
}
