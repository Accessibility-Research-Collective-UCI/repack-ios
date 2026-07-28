import Accessibility
import SwiftUI

/// Selects installed artifacts for dependency-safe deletion.
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
        let addedAutomatically = selection
            .subtracting(previous)
            .subtracting([item.id])
        let removedAutomatically = previous
            .subtracting(selection)
            .subtracting([item.id])
        if !addedAutomatically.isEmpty {
            AccessibilityNotification.Announcement(
                String(
                    localized:
                        "Also selected because of model dependencies: \(names(for: addedAutomatically))."
                )
            )
            .post()
        } else if !removedAutomatically.isEmpty {
            AccessibilityNotification.Announcement(
                String(
                    localized:
                        "Also deselected because the files are installed together: \(names(for: removedAutomatically))."
                )
            )
            .post()
        }
    }

    private func accessibilityHint(for item: StorageItem) -> String {
        let isSelected = selection.contains(item.id)
        let updated = model.deletionSelection(
            toggling: item,
            isSelected: !isSelected,
            current: selection
        )
        let automaticChanges = isSelected
            ? selection.subtracting(updated).subtracting([item.id])
            : updated.subtracting(selection).subtracting([item.id])
        guard !automaticChanges.isEmpty else {
            return String(localized: "Selects this model for removal.")
        }
        let changedNames = names(for: automaticChanges)
        if isSelected {
            return String(
                localized:
                    "Also deselects \(changedNames) because the files are installed together."
            )
        }
        return String(
            localized:
                "Also selects \(changedNames) because of model dependencies."
        )
    }

    private func names(for ids: Set<String>) -> String {
        model.modelStorageItems
            .filter { ids.contains($0.id) }
            .map(\.displayName)
            .formatted(.list(type: .and))
    }
}
