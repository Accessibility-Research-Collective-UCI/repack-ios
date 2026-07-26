import Accessibility
import SwiftUI

struct ModelManagerView: View {
    @Bindable var model: REPACKViewModel
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

struct ModelSelectionView: View {
    @Bindable var model: REPACKViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectingModelID: String?

    var body: some View {
        NavigationStack {
            List(model.localModels) { localModel in
                Button {
                    select(localModel)
                } label: {
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
                        if ModelManager.sameFile(model.modelURL, localModel.url) {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(
                    ModelManager.sameFile(model.modelURL, localModel.url)
                        ? .isSelected
                        : []
                )
                .accessibilityHint("Selects and loads this model.")
                .disabled(
                    selectingModelID != nil
                        || !model.supportsModel(at: localModel.url)
                )
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(selectingModelID != nil)
    }

    private func select(_ localModel: LocalModel) {
        guard selectingModelID == nil else { return }
        selectingModelID = localModel.id

        Task {
            await model.prepareModelSelection(localModel)
            AccessibilityNotification.Announcement(
                String(localized: "\(localModel.displayName) selected.")
            )
            .post()
            try? await Task.sleep(for: .seconds(1))
            dismiss()
            await model.loadPreparedModel()
        }
    }
}

#Preview("Model Download Progress") {
    let model = REPACKViewModel()
    model.phase = .downloading(name: DownloadableModel.e4b.displayName, progress: 0.42)
    model.modelDownloadProgress = ModelDownloadProgress(
        requestedModel: .e4b,
        currentModel: .e2b,
        fileIndex: 1,
        fileCount: 2,
        completedBytes: 2_624_025_940,
        totalBytes: 6_247_677_952
    )
    return ModelManagerView(model: model)
}

#Preview("Model Selection") {
    let model = REPACKViewModel()
    model.localModels = [
        LocalModel(
            url: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
            isBundled: true
        ),
        LocalModel(
            url: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
            isBundled: true
        )
    ]
    return ModelSelectionView(model: model)
}

private struct ManageModelStorageView: View {
    @Bindable var model: REPACKViewModel
    @State private var selection: Set<String> = []
    @State private var pendingPlan: ModelDeletionPlan?

    var body: some View {
        List {
            Section {
                ForEach(model.modelStorageItems) { item in
                    Toggle(
                        isOn: Binding(
                            get: { selection.contains(item.id) },
                            set: { updateSelection(for: item, isSelected: $0) }
                        )
                    ) {
                        VStack(alignment: .leading) {
                            Text(item.displayName)
                            Text(item.originDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let dependency = item.dependencyDescription {
                                Text(dependency)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.byteCount, format: .byteCount(style: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint(accessibilityHint(for: item))
                }
            } header: {
                Text("Models")
            } footer: {
                Text(
                    "Space to recover: \(selectedBytes.formatted(.byteCount(style: .file)))"
                )
            }

            Section {
                Button(selection.count == model.modelStorageItems.count
                    ? "Deselect All"
                    : "Select All"
                ) {
                    if selection.count == model.modelStorageItems.count {
                        selection.removeAll()
                    } else {
                        selection = Set(model.modelStorageItems.map(\.id))
                    }
                }

                Button("Delete Selected…", role: .destructive) {
                    pendingPlan = model.deletionPlan(for: selection)
                }
                .disabled(selection.isEmpty)
            }
        }
        .navigationTitle("Manage Storage")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Remove Models?",
            isPresented: Binding(
                get: { pendingPlan != nil },
                set: { if !$0 { pendingPlan = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let pendingPlan else { return }
                self.pendingPlan = nil
                Task {
                    await model.deleteModels(pendingPlan)
                    selection.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPlan = nil
            }
        } message: {
            Text(pendingPlan?.confirmationMessage ?? "")
        }
    }

    private var selectedBytes: Int64 {
        model.deletionPlan(for: selection).recoveredBytes
    }

    private func updateSelection(
        for item: ModelStorageItem,
        isSelected: Bool
    ) {
        let previous = selection
        selection = model.deletionSelection(
            toggling: item,
            isSelected: isSelected,
            current: selection
        )
        let changedAutomatically = selection
            .subtracting(previous)
            .subtracting([item.id])
        if let addedID = changedAutomatically.first,
            let added = model.modelStorageItems.first(where: { $0.id == addedID }) {
            AccessibilityNotification.Announcement(
                String(
                    localized:
                        "\(added.displayName) was also selected because of model dependencies."
                )
            )
            .post()
        }
    }

    private func accessibilityHint(for item: ModelStorageItem) -> String {
        if item.record.origin == .approved, item.record.model == .e2b,
            model.modelStorageItems.contains(where: {
                $0.record.origin == .approved && $0.record.model == .e4b
            }) {
            return String(
                localized:
                    "Gemma 4 E4B will also be selected because it requires this model."
            )
        }
        if item.record.origin == .approved, item.record.model == .e4b,
            model.modelStorageItems.contains(where: {
                $0.record.origin == .approved
                    && $0.record.model == .e2b
                    && !$0.record.explicitlyOwned
            }) {
            return String(
                localized:
                    "Its unused Gemma 4 E2B dependency will be selected by default."
            )
        }
        return String(localized: "Selects this model for removal.")
    }
}
