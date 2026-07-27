import Accessibility
import SwiftUI

struct ModelLibraryView: View {
    @Bindable var model: AppModel
    @State private var isCancelConfirmationPresented = false

    var body: some View {
        NavigationStack {
            List {
                if !model.localModels.isEmpty {
                    Section("On This Device") {
                        ForEach(model.localModels) { localModel in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(localModel.displayName)
                                    Text(localModel.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !model.supportsModel(at: localModel.url) {
                                        Text("Unavailable on this iPhone")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
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

                Section("Download") {
                    ForEach(DownloadableModel.allCases) { downloadable in
                        let isDownloaded = model.localModels.contains {
                            $0.url.lastPathComponent == downloadable.fileName
                        }
                        Button {
                            Task {
                                await model.prepareModelDownload(downloadable)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(downloadable.displayName)
                                    Text(downloadable.shortDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !model.supportsDownload(downloadable) {
                                        Text("Unavailable on this iPhone")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(
                                    systemName: isDownloaded
                                        ? "checkmark.circle.fill"
                                        : "arrow.down.circle"
                                )
                                    .foregroundStyle(
                                        isDownloaded ? Color.green : Color.accentColor
                                    )
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(downloadable.displayName)
                        .accessibilityValue(
                            isDownloaded ? "Downloaded" : ""
                        )
                        .accessibilityHint(
                            isDownloaded
                                ? "This model is already on this device."
                                : downloadable.shortDescription
                        )
                        .disabled(model.isBusy || !model.supportsDownload(downloadable))
                    }

                    if model.isModelDownloadActive {
                        Text("Keep this page open while the models are downloading.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if model.isModelDownloadWaiting {
                            ProgressView {
                                Text("Waiting for download to start")
                            }
                            .accessibilityLabel("Model download")
                            .accessibilityValue("Waiting to start")
                        } else if let progress = model.modelDownloadProgress {
                            VStack(alignment: .leading) {
                                Text(progress.currentFileDescription)
                                    .font(.subheadline)
                                ProgressView(value: progress.fractionCompleted)
                                Text(
                                    progress.fractionCompleted,
                                    format: .percent.precision(.fractionLength(0))
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Model download")
                            .accessibilityValue(progress.accessibilityValue)
                        }

                        Button(
                            "Cancel Download",
                            systemImage: "xmark.circle",
                            role: .destructive
                        ) {
                            isCancelConfirmationPresented = true
                        }
                        .accessibilityHint(
                            "Stops the download and removes temporary files."
                        )
                        .alert(
                            "Cancel Download?",
                            isPresented: $isCancelConfirmationPresented
                        ) {
                            Button("Keep Downloading", role: .cancel) {}
                            Button("Cancel Download", role: .destructive) {
                                Task {
                                    await model.cancelModelDownload()
                                }
                            }
                        } message: {
                            Text(
                                "The current download will stop and temporary files will be removed."
                            )
                        }
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
}
