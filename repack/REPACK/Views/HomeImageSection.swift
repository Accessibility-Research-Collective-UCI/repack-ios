import PhotosUI
import SwiftUI
import UIKit

struct HomeImageSection: View {
    let model: AppModel
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showCamera: Bool

    var body: some View {
        Section("Image") {
            VStack(spacing: 16) {
                if let imageURL = model.selectedImageURL {
                    LocalImagePreview(url: imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Selected image")

                    Divider()

                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        Task {
                            await model.removeAttachedImage()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isBusy)
                } else {
                    ContentUnavailableView(
                        "Choose an Image",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Select a photo or take a new one to begin.")
                    )
                    .frame(minHeight: 180)
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { imageButtons }
                    VStack(spacing: 12) { imageButtons }
                }
                .controlSize(.large)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var imageButtons: some View {
        let iconColor = imageButtonTint

        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label {
                Text("Photos")
            } icon: {
                Image(systemName: "photo")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(iconColor)
            }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!imageButtonsEnabled)

        Button {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showCamera = true
            } else {
                model.errorMessage = String(localized: "Camera is not available on this device.")
            }
        } label: {
            Label {
                Text("Camera")
            } icon: {
                Image(systemName: "camera")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(iconColor)
            }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!imageButtonsEnabled)
    }

    private var imageButtonsEnabled: Bool {
        model.isEngineReady
    }

    private var imageButtonTint: Color {
        imageButtonsEnabled ? .accentColor : .secondary
    }
}
