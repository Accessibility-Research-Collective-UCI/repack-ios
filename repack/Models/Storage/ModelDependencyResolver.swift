import Foundation

/// Resolves deletion selection through the catalog's dependency graph.
nonisolated struct ModelDependencyResolver {
    let items: [StorageItem]

    func selection(
        toggling item: StorageItem,
        isSelected: Bool,
        current: Set<String>
    ) -> Set<String> {
        if isSelected {
            return resolvedSelection(from: current.union([item.id]))
        }

        var selection = current
        selection.remove(item.id)
        guard let model = approvedModel(for: item) else {
            return selection
        }

        if !item.record.explicitlyOwned {
            dependentItems(of: model).forEach {
                selection.remove($0.id)
            }
        }
        dependencyItems(of: model)
            .filter { !$0.record.explicitlyOwned }
            .forEach { selection.remove($0.id) }
        return selection
    }

    func deletionPlan(for selection: Set<String>) -> DeletionPlan {
        let resolved = resolvedSelection(from: selection)
        return DeletionPlan(
            items: items.filter { resolved.contains($0.id) }
        )
    }

    private func resolvedSelection(from initial: Set<String>) -> Set<String> {
        var selection = initial
        var changed = true

        while changed {
            changed = false
            let selectedItems = items.filter { selection.contains($0.id) }
            for item in selectedItems {
                guard let model = approvedModel(for: item) else { continue }

                for dependent in dependentItems(of: model)
                    where selection.insert(dependent.id).inserted {
                    changed = true
                }
                for dependency in dependencyItems(of: model)
                    where !dependency.record.explicitlyOwned
                        && selection.insert(dependency.id).inserted {
                    changed = true
                }
            }
        }
        return selection
    }

    private func approvedModel(for item: StorageItem) -> DownloadableModel? {
        guard item.record.origin == .approved else { return nil }
        return item.record.model
    }

    private func dependencyItems(
        of model: DownloadableModel
    ) -> [StorageItem] {
        let dependencies = Set(model.descriptor.dependencies)
        return items.filter {
            guard let candidate = approvedModel(for: $0) else { return false }
            return dependencies.contains(candidate)
        }
    }

    private func dependentItems(
        of model: DownloadableModel
    ) -> [StorageItem] {
        items.filter {
            guard let candidate = approvedModel(for: $0) else { return false }
            return candidate.descriptor.dependencies.contains(model)
        }
    }
}
