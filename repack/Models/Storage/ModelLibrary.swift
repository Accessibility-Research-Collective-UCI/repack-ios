import Foundation

struct ModelLibrary {
    private let modelExtension = "litertlm"
    private let downloadService: any ModelDownloadServicing
    private let installationStore: ModelInstallationStore
    private let fileManager: FileManager

    init(
        downloadService: any ModelDownloadServicing = ModelDownloadService(),
        installationDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.downloadService = downloadService
        self.fileManager = fileManager
        installationStore = ModelInstallationStore(defaults: installationDefaults)
    }

    func refreshLocalModels() -> [LocalModel] {
        installationStore.reconcile(
            localModels(),
            installedFiles: installedModelFiles()
        )
    }

    func markExplicitOwnership(of model: LocalModel) {
        guard model.origin == .approved,
            let downloadable = DownloadableModel(modelURL: model.url)
        else {
            return
        }
        installationStore.markExplicit(downloadable)
    }

    func prepareDownloadPlan(for model: DownloadableModel) async throws -> DownloadPlan {
        #if DEBUG
            let policy: DownloadPolicy = .validateAndRemove
        #else
            let policy: DownloadPolicy = .install
        #endif

        let plan = try await downloadService.preparePlan(
            for: model,
            policy: policy
        )
        #if !DEBUG
        if plan.files.isEmpty {
            installationStore.markExplicit(model)
        }
        #endif
        return plan
    }

    func download(
        plan: DownloadPlan,
        progressHandler: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> DownloadOutcome {
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

    func storageItems(from models: [LocalModel]) -> [StorageItem] {
        let records = Dictionary(
            uniqueKeysWithValues: installationStore.records().map {
                ($0.fileName, $0)
            }
        )
        let savedModels = models.filter { !$0.isBundled }
        let captionPaths = Set(savedModels.map { $0.url.standardizedFileURL.path })
        let artifactModels = installedModelFiles().compactMap { url -> LocalModel? in
            guard !captionPaths.contains(url.standardizedFileURL.path),
                  let record = records[url.lastPathComponent] else {
                return nil
            }
            return LocalModel(
                url: url,
                isBundled: false,
                origin: record.origin
            )
        }
        return (savedModels + artifactModels).compactMap { model in
            records[model.url.lastPathComponent].map {
                StorageItem(model: model, record: $0)
            }
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
    }

    func isInstalled(_ model: DownloadableModel) -> Bool {
        #if DEBUG
            if model == .embeddingGemma,
               EmbeddingModelResources.bundled() != nil {
                return true
            }
        #endif

        let installedNames = Set(
            (installedModelFiles() + localModels().map(\.url))
                .map(\.lastPathComponent)
        )
        return model.dependencyOrder.allSatisfy {
            installedNames.contains($0.fileName)
        }
    }

    nonisolated func deletionSelection(
        toggling item: StorageItem,
        isSelected: Bool,
        current: Set<String>,
        items: [StorageItem]
    ) -> Set<String> {
        ModelDependencyResolver(items: items).selection(
            toggling: item,
            isSelected: isSelected,
            current: current
        )
    }

    nonisolated func deletionPlan(
        selection: Set<String>,
        items: [StorageItem]
    ) -> DeletionPlan {
        ModelDependencyResolver(items: items).deletionPlan(for: selection)
    }

    func deleteModels(_ plan: DeletionPlan) throws {
        for item in plan.items {
            try fileManager.removeItem(at: item.model.url)
            let legacyMarker = item.model.url.deletingLastPathComponent()
                .appending(path: ".\(item.model.url.lastPathComponent).verified.plist")
            try? fileManager.removeItem(at: legacyMarker)
        }
        installationStore.remove(plan.items.map(\.record))
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

        if let directory = try? Self.modelsDirectory(fileManager: fileManager) {
            let savedModels = (try? fileManager.contentsOfDirectory(
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

    private func installedModelFiles() -> [URL] {
        guard let directory = try? Self.modelsDirectory(fileManager: fileManager)
        else {
            return []
        }
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
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

    nonisolated static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let appURL = URL.applicationSupportDirectory
            .appending(path: "repack", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        return appURL
    }

    nonisolated static func modelsDirectory(
        fileManager: FileManager
    ) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager)
            .appending(path: "Models", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
