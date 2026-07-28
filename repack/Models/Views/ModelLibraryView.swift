import SwiftUI

/// Lists installed and downloadable model resources.
struct ModelLibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if hasOnDeviceModels {
                    Section("On This Device") {
                        ForEach(model.localModels) { localModel in
                            onDeviceModelRow(
                                name: localModel.displayName,
                                detail: localModel.detail,
                                isSupported: model.supportsModel(
                                    at: localModel.url
                                )
                            )
                        }

                        if isEmbeddingModelInstalled {
                            onDeviceModelRow(
                                name: DownloadableModel.embeddingGemma.displayName,
                                detail: DownloadableModel.embeddingGemma.shortDescription,
                                isSupported: true
                            )
                        }
                    }
                }

                if !model.modelStorageItems.isEmpty {
                    Section {
                        NavigationLink {
                            ManageModelStorageView(model: model)
                        } label: {
                            Label("Manage Storage", systemImage: "externaldrive")
                        }
                        .disabled(model.isBusy)
                    }
                }

                Section {
                    ForEach(DownloadableModel.imageCaptioningModels) {
                        downloadableRow(for: $0)
                    }
                } header: {
                    Text("Image Captioning Models")
                } footer: {
                    Text(
                        "Image captioning models describe the image and break captions into atomic statements."
                    )
                }

                Section {
                    ForEach(DownloadableModel.embeddingModels) {
                        downloadableRow(for: $0)
                    }
                } header: {
                    Text("Embedding Models")
                } footer: {
                    Text(
                        "Embedding models compare atomic statements from broken down captions by semantic similarity."
                    )
                }

                if model.isModelDownloadActive {
                    ModelDownloadProgressSection(
                        isWaiting: model.isModelDownloadWaiting,
                        progress: model.modelDownloadProgress
                    ) {
                        await model.cancelModelDownload()
                    }
                }
            }
            .navigationTitle("Manage Installed Models")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(item: $model.modelDownloadAlert) { alert in
            switch alert {
            case .confirmation(let plan):
                Alert(
                    title: Text(plan.confirmationTitle),
                    message: Text(plan.confirmationMessage),
                    primaryButton: .default(Text("Download")) {
                        Task {
                            await model.confirmModelDownload(plan)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .foregroundFallback(let plan):
                Alert(
                    title: Text("Background Download Unavailable"),
                    message: Text(
                        "This iPhone could not start a background download. You can continue with a foreground download, but you must keep the app open until it finishes."
                    ),
                    primaryButton: .default(Text("Download with App Open")) {
                        model.confirmForegroundModelDownload(plan)
                    },
                    secondaryButton: .cancel()
                )
            case .message(_, let title, let message):
                Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var hasOnDeviceModels: Bool {
        !model.localModels.isEmpty || isEmbeddingModelInstalled
    }

    private var isEmbeddingModelInstalled: Bool {
        model.isModelInstalled(.embeddingGemma)
            || model.modelStorageItems.contains {
                $0.record.model == .embeddingGemma
            }
    }

    private func onDeviceModelRow(
        name: String,
        detail: String,
        isSupported: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isSupported {
                    Text("Unavailable on this iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func downloadableRow(
        for downloadable: DownloadableModel
    ) -> some View {
        DownloadableModelRow(
            model: downloadable,
            isDownloaded: model.isModelInstalled(downloadable),
            isSupported: model.supportsDownload(downloadable),
            isDisabled: model.isBusy
        ) {
            Task {
                await model.prepareModelDownload(downloadable)
            }
        }
    }
}
