import Foundation

struct ModelInstallationStore {
    private let key = "ModelInstallationRecords"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func records() -> [InstallationRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? PropertyListDecoder().decode(
                  [InstallationRecord].self,
                  from: data
              ) else {
            return []
        }
        return records
    }

    func reconcile(
        _ models: [LocalModel],
        installedFiles: [URL]
    ) -> [LocalModel] {
        let existingNames = Set(installedFiles.map(\.lastPathComponent))
        var records = records().filter { existingNames.contains($0.fileName) }

        for url in installedFiles {
            let fileName = url.lastPathComponent
            let byteCount = Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            if let index = records.firstIndex(where: { $0.fileName == fileName }) {
                records[index].byteCount = byteCount
            } else {
                let approvedModel = DownloadableModel.allCases.first {
                    $0.fileName == fileName
                }
                records.append(
                    InstallationRecord(
                        fileName: fileName,
                        origin: approvedModel == nil ? .imported : .approved,
                        model: approvedModel,
                        explicitlyOwned:
                            approvedModel?.isEmbeddingDependency != true,
                        requiredBy: [],
                        byteCount: byteCount
                    )
                )
            }
        }

        rebuildDependencies(in: &records)
        save(records)

        let recordsByName = Dictionary(
            uniqueKeysWithValues: records.map { ($0.fileName, $0) }
        )
        return models.map { model in
            guard !model.isBundled,
                  let record = recordsByName[model.url.lastPathComponent] else {
                return model
            }
            return LocalModel(
                url: model.url,
                isBundled: false,
                origin: record.origin
            )
        }
    }

    func recordDownload(_ plan: DownloadPlan) {
        var records = records()
        for file in plan.files {
            let descriptor = file.descriptor
            let index = records.firstIndex {
                $0.fileName == descriptor.fileName
            }
            let explicitlyOwned = descriptor.model == plan.requestedModel
                || (index.map { records[$0].explicitlyOwned } ?? false)
            let record = InstallationRecord(
                fileName: descriptor.fileName,
                origin: .approved,
                model: descriptor.model,
                explicitlyOwned: explicitlyOwned,
                requiredBy: [],
                byteCount: file.byteCount
            )
            if let index {
                records[index] = record
            } else {
                records.append(record)
            }
        }

        rebuildDependencies(in: &records)
        save(records)
    }

    func markExplicit(_ model: DownloadableModel) {
        var records = records()
        guard let index = records.firstIndex(where: {
            $0.origin == .approved && $0.model == model
        }) else {
            return
        }
        records[index].explicitlyOwned = true
        save(records)
    }

    func remove(_ removed: [InstallationRecord]) {
        let removedNames = Set(removed.map(\.fileName))
        var records = records().filter { !removedNames.contains($0.fileName) }
        rebuildDependencies(in: &records)
        for index in records.indices
            where !records[index].explicitlyOwned
                && records[index].requiredBy.isEmpty {
            records[index].explicitlyOwned = true
        }
        save(records)
    }

    private func rebuildDependencies(
        in records: inout [InstallationRecord]
    ) {
        for index in records.indices {
            records[index].requiredBy.removeAll()
        }
        let installedModels = Set(
            records.compactMap { record in
                record.origin == .approved ? record.model : nil
            }
        )
        for dependent in installedModels {
            for dependency in dependent.descriptor.dependencies
                where installedModels.contains(dependency) {
                guard let index = records.firstIndex(where: {
                    $0.origin == .approved && $0.model == dependency
                }) else {
                    continue
                }
                records[index].requiredBy.insert(dependent)
            }
        }
    }

    private func save(_ records: [InstallationRecord]) {
        guard let data = try? PropertyListEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
