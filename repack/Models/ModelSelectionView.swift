import Accessibility
import SwiftUI

struct ModelSelectionView: View {
    @Bindable var model: AppModel
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
                        if ModelLibrary.sameFile(model.modelURL, localModel.url) {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(
                    ModelLibrary.sameFile(model.modelURL, localModel.url)
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
            dismiss()
            await model.loadPreparedModel()
        }
    }
}
