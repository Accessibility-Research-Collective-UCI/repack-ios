import Accessibility
import SwiftUI

struct ManageModelStorageView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<String> = []
    @State private var pendingPlan: DeletionPlan?

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
        for item: StorageItem,
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

    private func accessibilityHint(for item: StorageItem) -> String {
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
