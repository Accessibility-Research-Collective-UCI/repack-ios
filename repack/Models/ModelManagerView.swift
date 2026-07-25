import SwiftUI
import UniformTypeIdentifiers

struct ModelManagerView: View {
    @Bindable var model: REPACKViewModel
    let importAction: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !model.localModels.isEmpty {
                    Section("On This Device") {
                        ForEach(model.localModels) { localModel in
                            Button {
                                Task {
                                    await model.selectModel(localModel)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(localModel.displayName)
                                        Text(localModel.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if ModelManager.sameFile(model.modelURL, localModel.url) {
                                        Image(systemName: "checkmark")
                                            .accessibilityLabel("Selected")
                                    }
                                }
                            }
                            .accessibilityAddTraits(
                                ModelManager.sameFile(model.modelURL, localModel.url)
                                    ? .isSelected
                                    : []
                            )
                            .disabled(model.isBusy)
                        }
                    }
                }

                Section("Download") {
                    ForEach(DownloadableModel.allCases) { downloadable in
                        Button {
                            Task {
                                await model.downloadModel(downloadable)
                                if model.phase == .ready {
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(downloadable.displayName)
                                    Text("\(downloadable.approximateSize) · \(downloadable.detail)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .disabled(model.isBusy)
                    }

                    if case .downloading(_, let progress) = model.phase {
                        ProgressView(value: progress)
                            .accessibilityLabel("Model download")
                            .accessibilityValue(
                                Text(
                                    progress,
                                    format: .percent.precision(.fractionLength(0))
                                )
                            )
                    }
                }

                Section {
                    Button("Import Model", systemImage: "square.and.arrow.down") {
                        importAction()
                    }
                    .disabled(model.isBusy)
                } footer: {
                    Text("Choose a compatible .litertlm bundle with speculative decoding support.")
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

extension UTType {
    static let liteRTLMModel = UTType(importedAs: "com.uci.repack.litertlm")
}
