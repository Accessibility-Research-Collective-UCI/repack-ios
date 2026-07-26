import Foundation

nonisolated enum ModelInstallationOrigin: String, Codable, Sendable {
    case bundled
    case approved
    case imported
}

nonisolated struct ModelInstallationRecord: Codable, Equatable, Sendable {
    let fileName: String
    let origin: ModelInstallationOrigin
    let model: DownloadableModel?
    var explicitlyOwned: Bool
    var requiredBy: Set<DownloadableModel>
    var byteCount: Int64
}

nonisolated struct LocalModel: Identifiable, Equatable, Sendable {
    let url: URL
    let isBundled: Bool
    let origin: ModelInstallationOrigin

    init(
        url: URL,
        isBundled: Bool,
        origin: ModelInstallationOrigin? = nil
    ) {
        self.url = url
        self.isBundled = isBundled
        self.origin = origin ?? (isBundled ? .bundled : .imported)
    }

    nonisolated var id: String { url.path }
    nonisolated var displayName: String {
        DownloadableModel.displayName(for: url)
    }
    nonisolated var detail: String {
        DownloadableModel.shortDescription(for: url)
    }
}

nonisolated struct ModelStorageItem: Identifiable, Equatable, Sendable {
    let model: LocalModel
    let record: ModelInstallationRecord

    var id: String { model.id }
    var displayName: String { model.displayName }
    var byteCount: Int64 { record.byteCount }

    var originDescription: String {
        switch record.origin {
        case .approved:
            String(localized: "Downloaded from Hugging Face")
        case .imported:
            String(localized: "Imported")
        case .bundled:
            String(localized: "Bundled with this Debug build")
        }
    }

    var dependencyDescription: String? {
        guard record.requiredBy.contains(.e4b) else { return nil }
        return String(localized: "Required by Gemma 4 E4B")
    }
}

nonisolated struct ModelDeletionPlan: Equatable, Sendable {
    let items: [ModelStorageItem]

    var ids: Set<String> { Set(items.map(\.id)) }
    var recoveredBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }

    var confirmationMessage: String {
        let names = items.map(\.displayName).formatted(.list(type: .and))
        let size = recoveredBytes.formatted(.byteCount(style: .file))
        return String(
            localized:
                "Remove \(names)? This will recover approximately \(size)."
        )
    }
}

struct ModelManager {
    private let storedModelPathKey = "GemmaModelPath"
    private let modelExtension = "litertlm"
    private let downloadService: any ModelDownloadServicing
    private let installationStore: ModelInstallationStore

    init(
        downloadService: any ModelDownloadServicing = ModelDownloadService(),
        installationDefaults: UserDefaults = .standard
    ) {
        self.downloadService = downloadService
        installationStore = ModelInstallationStore(defaults: installationDefaults)
    }

    func refreshLocalModels(currentModelURL: URL?) -> (models: [LocalModel], selectedModelURL: URL?) {
        let models = installationStore.reconcile(localModels())
        var selectedModelURL = currentModelURL

        if selectedModelURL == nil {
            selectedModelURL = storedModelURL() ?? models.first?.url
        } else if let currentModelURL, !models.contains(where: { Self.sameFile($0.url, currentModelURL) }) {
            selectedModelURL = models.first?.url
            UserDefaults.standard.removeObject(forKey: storedModelPathKey)
        }

        return (models, selectedModelURL)
    }

    func rememberSelectedModel(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: storedModelPathKey)
    }

    func markExplicitOwnership(of model: LocalModel) {
        guard model.origin == .approved,
            let downloadable = DownloadableModel(modelURL: model.url)
        else {
            return
        }
        installationStore.markExplicit(downloadable)
    }

    func prepareDownloadPlan(for model: DownloadableModel) async throws -> ModelDownloadPlan {
        #if DEBUG
            let validatesWithoutKeepingFiles = true
        #else
            let validatesWithoutKeepingFiles = false
        #endif

        let plan = try await downloadService.preparePlan(
            for: model,
            validatesWithoutKeepingFiles: validatesWithoutKeepingFiles
        )
        #if !DEBUG
        if plan.files.isEmpty {
            installationStore.markExplicit(model)
        }
        #endif
        return plan
    }

    func download(
        plan: ModelDownloadPlan,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws -> ModelDownloadOutcome {
        let outcome = try await downloadService.execute(
            plan,
            progressHandler: progressHandler
        )
        if case .installed = outcome {
            installationStore.recordDownload(plan)
        }
        return outcome
    }

    func cancelDownload() async {
        await downloadService.cancelCurrentDownload()
    }

    func storageItems(from models: [LocalModel]) -> [ModelStorageItem] {
        let records = Dictionary(
            uniqueKeysWithValues: installationStore.records().map {
                ($0.fileName, $0)
            }
        )
        return models.compactMap { model in
            guard !model.isBundled,
                let record = records[model.url.lastPathComponent]
            else {
                return nil
            }
            return ModelStorageItem(model: model, record: record)
        }
    }

    nonisolated func deletionSelection(
        toggling item: ModelStorageItem,
        isSelected: Bool,
        current: Set<String>,
        items: [ModelStorageItem]
    ) -> Set<String> {
        var selection = current
        let approvedE2B = items.first {
            $0.record.origin == .approved && $0.record.model == .e2b
        }
        let approvedE4B = items.first {
            $0.record.origin == .approved && $0.record.model == .e4b
        }

        if isSelected {
            selection.insert(item.id)
            if item.id == approvedE2B?.id, let approvedE4B {
                selection.insert(approvedE4B.id)
            } else if item.id == approvedE4B?.id,
                let approvedE2B,
                !approvedE2B.record.explicitlyOwned {
                selection.insert(approvedE2B.id)
            }
        } else {
            selection.remove(item.id)
            if item.id == approvedE4B?.id, let approvedE2B {
                selection.remove(approvedE2B.id)
            }
        }
        return selection
    }

    nonisolated func deletionPlan(
        selection: Set<String>,
        items: [ModelStorageItem]
    ) -> ModelDeletionPlan {
        var resolved = selection
        if let approvedE2B = items.first(where: {
            $0.record.origin == .approved && $0.record.model == .e2b
        }), resolved.contains(approvedE2B.id),
            let approvedE4B = items.first(where: {
                $0.record.origin == .approved && $0.record.model == .e4b
            }) {
            resolved.insert(approvedE4B.id)
        }
        return ModelDeletionPlan(
            items: items.filter { resolved.contains($0.id) }
        )
    }

    func deleteModels(_ plan: ModelDeletionPlan) throws {
        for item in plan.items {
            try FileManager.default.removeItem(at: item.model.url)
            let legacyMarker = item.model.url.deletingLastPathComponent()
                .appending(path: ".\(item.model.url.lastPathComponent).verified.plist")
            try? FileManager.default.removeItem(at: legacyMarker)
        }
        installationStore.remove(plan.items.map(\.record))
    }

    func isDownloadInstalled(_ model: DownloadableModel) async -> Bool {
        await downloadService.isInstalled(model)
    }

    func cleanDownloadStagingDirectory() async {
        await downloadService.cleanStagingDirectory()
    }

    private func localModels() -> [LocalModel] {
        var models: [LocalModel] = []

        #if DEBUG
            models += (
                Bundle.main.urls(
                    forResourcesWithExtension: modelExtension,
                    subdirectory: "DevelopmentModels"
                ) ?? []
            )
            .map { LocalModel(url: $0, isBundled: true) }
        #endif

        if let directory = try? Self.modelsDirectory() {
            let savedModels = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []

            models += savedModels
                .filter { $0.pathExtension == modelExtension }
                .map { LocalModel(url: $0, isBundled: false) }
        }

        var seenPaths = Set<String>()
        return models.filter { model in
            seenPaths.insert(model.url.standardizedFileURL.path).inserted
        }
        .sorted { lhs, rhs in
            if lhs.isBundled != rhs.isBundled {
                return lhs.isBundled
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func storedModelURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: storedModelPathKey),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    nonisolated static func processingModelURL(
        for samplingModelURL: URL,
        availableModels: [LocalModel]
    ) -> URL? {
        guard isE4B(samplingModelURL) else {
            return samplingModelURL
        }

        return availableModels.first { isE2B($0.url) }?.url
    }

    nonisolated static func isE2B(_ modelURL: URL) -> Bool {
        DownloadableModel(modelURL: modelURL) == .e2b
    }

    nonisolated static func isE4B(_ modelURL: URL) -> Bool {
        DownloadableModel(modelURL: modelURL) == .e4b
    }

    nonisolated static func applicationSupportDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appURL = baseURL.appendingPathComponent("repack", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        return appURL
    }

    private nonisolated static func modelsDirectory() throws -> URL {
        let directory = try applicationSupportDirectory().appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct ModelInstallationStore {
    private let key = "ModelInstallationRecords"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func records() -> [ModelInstallationRecord] {
        guard let data = defaults.data(forKey: key),
            let records = try? PropertyListDecoder().decode(
                [ModelInstallationRecord].self,
                from: data
            )
        else {
            return []
        }
        return records
    }

    func reconcile(_ models: [LocalModel]) -> [LocalModel] {
        let savedModels = models.filter { !$0.isBundled }
        let existingNames = Set(savedModels.map { $0.url.lastPathComponent })
        var records = records().filter { existingNames.contains($0.fileName) }

        for model in savedModels {
            let fileName = model.url.lastPathComponent
            let byteCount = Int64(
                (try? model.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            if let index = records.firstIndex(where: { $0.fileName == fileName }) {
                records[index].byteCount = byteCount
            } else {
                let approvedModel = DownloadableModel.allCases.first {
                    $0.fileName == fileName
                }
                records.append(
                    ModelInstallationRecord(
                        fileName: fileName,
                        origin: approvedModel == nil ? .imported : .approved,
                        model: approvedModel,
                        explicitlyOwned: true,
                        requiredBy: [],
                        byteCount: byteCount
                    )
                )
            }
        }

        for index in records.indices {
            records[index].requiredBy.removeAll()
        }
        if let e2BIndex = records.firstIndex(where: {
            $0.origin == .approved && $0.model == .e2b
        }), records.contains(where: {
            $0.origin == .approved && $0.model == .e4b
        }) {
            records[e2BIndex].requiredBy.insert(.e4b)
        }
        save(records)

        let recordsByName = Dictionary(
            uniqueKeysWithValues: records.map { ($0.fileName, $0) }
        )
        return models.map { model in
            guard !model.isBundled,
                let record = recordsByName[model.url.lastPathComponent]
            else {
                return model
            }
            return LocalModel(
                url: model.url,
                isBundled: false,
                origin: record.origin
            )
        }
    }

    func recordDownload(_ plan: ModelDownloadPlan) {
        var records = records()
        for file in plan.files {
            let descriptor = file.descriptor
            let index = records.firstIndex {
                $0.fileName == descriptor.fileName
            }
            let explicitlyOwned = descriptor.model == plan.requestedModel
                || (index.map { records[$0].explicitlyOwned } ?? false)
            let record = ModelInstallationRecord(
                fileName: descriptor.fileName,
                origin: .approved,
                model: descriptor.model,
                explicitlyOwned: explicitlyOwned,
                requiredBy: descriptor.model == .e2b && plan.requestedModel == .e4b
                    ? [.e4b]
                    : [],
                byteCount: file.byteCount
            )
            if let index {
                records[index] = record
            } else {
                records.append(record)
            }
        }

        if plan.requestedModel == .e4b,
            let e2BIndex = records.firstIndex(where: {
                $0.origin == .approved && $0.model == .e2b
            }) {
            records[e2BIndex].requiredBy.insert(.e4b)
        }
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

    func remove(_ removed: [ModelInstallationRecord]) {
        let removedNames = Set(removed.map(\.fileName))
        let removedE4B = removed.contains {
            $0.origin == .approved && $0.model == .e4b
        }
        let removedE2B = removed.contains {
            $0.origin == .approved && $0.model == .e2b
        }
        var records = records().filter { !removedNames.contains($0.fileName) }
        if removedE4B, !removedE2B,
            let e2BIndex = records.firstIndex(where: {
                $0.origin == .approved && $0.model == .e2b
            }) {
            records[e2BIndex].requiredBy.remove(.e4b)
            records[e2BIndex].explicitlyOwned = true
        }
        save(records)
    }

    private func save(_ records: [ModelInstallationRecord]) {
        guard let data = try? PropertyListEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
