import CryptoKit
import Foundation

nonisolated protocol ModelStorageCapacityProviding: Sendable {
    func availableCapacity(at directory: URL) throws -> Int64?
}

nonisolated struct VolumeModelStorageCapacityProvider: ModelStorageCapacityProviding {
    func availableCapacity(at directory: URL) throws -> Int64? {
        let values = try directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values.volumeAvailableCapacityForImportantUsage
    }
}

nonisolated protocol ModelDownloadServicing: Sendable {
    func preparePlan(
        for model: DownloadableModel,
        policy: DownloadPolicy
    ) async throws -> DownloadPlan

    func execute(
        _ plan: DownloadPlan,
        progressHandler: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> DownloadOutcome

    func isInstalled(_ model: DownloadableModel) async -> Bool
    func cancelCurrentDownload() async
    func cleanStagingDirectory() async
}

actor ModelDownloadService: ModelDownloadServicing {
    private static let capacityHeadroom: Int64 = 512 * 1_024 * 1_024

    private let hub: any ModelHubDownloading
    private let capacityProvider: any ModelStorageCapacityProviding
    private let baseDirectory: URL?
    private let fileManager: FileManager

    init(
        hub: any ModelHubDownloading = SwiftHuggingFaceModelHub(),
        capacityProvider: any ModelStorageCapacityProviding =
            VolumeModelStorageCapacityProvider(),
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.hub = hub
        self.capacityProvider = capacityProvider
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func preparePlan(
        for model: DownloadableModel,
        policy: DownloadPolicy
    ) async throws -> DownloadPlan {
        let dependencyAlreadyInstalled =
            model == .e4b
            && policy == .install
            && isInstalledFile(.e2b)

        let requiredModels = model.dependencyOrder.filter {
            policy == .validateAndRemove || !isInstalledFile($0)
        }
        var files: [DownloadFile] = []
        files.reserveCapacity(requiredModels.count)

        for requiredModel in requiredModels {
            let descriptor = requiredModel.descriptor
            let byteCount = try await hub.fileSize(for: descriptor)
            files.append(
                DownloadFile(
                    descriptor: descriptor,
                    byteCount: byteCount
                )
            )
        }

        let plan = DownloadPlan(
            requestedModel: model,
            files: files,
            dependencyAlreadyInstalled: dependencyAlreadyInstalled,
            policy: policy
        )
        if !files.isEmpty {
            try checkAvailableCapacity(requiredBytes: plan.totalBytes)
        }
        return plan
    }

    func execute(
        _ plan: DownloadPlan,
        progressHandler: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> DownloadOutcome {
        guard !plan.files.isEmpty else {
            return .installed(
                try modelsDirectory().appending(path: plan.requestedModel.fileName)
            )
        }

        try checkAvailableCapacity(requiredBytes: plan.totalBytes)

        let transactionDirectory = try stagingDirectory()
            .appending(path: plan.id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(transactionDirectory)
        defer {
            try? fileManager.removeItem(at: transactionDirectory)
        }

        var completedBytes: Int64 = 0
        var validatedDownloads: [(ModelDescriptor, URL)] = []
        var installedRequestedModelURL: URL?

        for (offset, file) in plan.files.enumerated() {
            try Task.checkCancellation()

            let descriptor = file.descriptor
            let destination = transactionDirectory.appending(path: descriptor.fileName)
            let completedBeforeFile = completedBytes

            await progressHandler(
                progress(
                    for: plan,
                    currentModel: descriptor.model,
                    fileIndex: offset + 1,
                    completedBytes: completedBeforeFile
                )
            )

            let downloadedURL = try await hub.download(
                descriptor,
                byteCount: file.byteCount,
                to: destination
            ) { fraction in
                let fileBytes = Int64(
                    (Double(file.byteCount) * min(max(fraction, 0), 1))
                        .rounded(.down)
                )
                await progressHandler(
                    DownloadProgress(
                        requestedModel: plan.requestedModel,
                        currentModel: descriptor.model,
                        fileIndex: offset + 1,
                        fileCount: plan.files.count,
                        completedBytes: completedBeforeFile + fileBytes,
                        totalBytes: plan.totalBytes
                    )
                )
            }

            try await validateChecksum(downloadedURL, against: descriptor)
            completedBytes += file.byteCount

            if plan.policy == .validateAndRemove {
                try fileManager.removeItem(at: downloadedURL)
            } else {
                validatedDownloads.append((descriptor, downloadedURL))
            }

            await progressHandler(
                progress(
                    for: plan,
                    currentModel: descriptor.model,
                    fileIndex: offset + 1,
                    completedBytes: completedBytes
                )
            )
        }

        if plan.policy == .validateAndRemove {
            return .validatedAndRemoved
        }

        for (descriptor, downloadedURL) in validatedDownloads {
            let installedURL = try promote(
                downloadedURL,
                descriptor: descriptor
            )
            if descriptor.model == plan.requestedModel {
                installedRequestedModelURL = installedURL
            }
        }
        if let installedRequestedModelURL {
            return .installed(installedRequestedModelURL)
        }

        let installedURL = try modelsDirectory()
            .appending(path: plan.requestedModel.fileName)
        guard isInstalledFile(plan.requestedModel) else {
            throw DownloadError.missingDownloadedFile
        }
        return .installed(installedURL)
    }

    func isInstalled(_ model: DownloadableModel) -> Bool {
        isInstalledFile(model)
    }

    func cancelCurrentDownload() async {
        await hub.cancelDownload()
    }

    func cleanStagingDirectory() {
        guard let directory = try? stagingDirectory() else { return }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? excludeFromBackup(directory)
    }

    private func progress(
        for plan: DownloadPlan,
        currentModel: DownloadableModel,
        fileIndex: Int,
        completedBytes: Int64
    ) -> DownloadProgress {
        DownloadProgress(
            requestedModel: plan.requestedModel,
            currentModel: currentModel,
            fileIndex: fileIndex,
            fileCount: plan.files.count,
            completedBytes: completedBytes,
            totalBytes: plan.totalBytes
        )
    }

    private func validateChecksum(
        _ fileURL: URL,
        against descriptor: ModelDescriptor
    ) async throws {
        let digest = try await sha256(of: fileURL)
        guard digest == descriptor.sha256 else {
            throw DownloadError.invalidChecksum(model: descriptor.model)
        }
    }

    private func sha256(of fileURL: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            await Task.yield()
        }

        return hasher.finalize().map { byte in
            let value = String(byte, radix: 16)
            return value.count == 1 ? "0\(value)" : value
        }
        .joined()
    }

    private func promote(
        _ stagedURL: URL,
        descriptor: ModelDescriptor
    ) throws -> URL {
        let destination = try modelsDirectory()
            .appending(path: descriptor.fileName)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destination)
        }
        try excludeFromBackup(destination)
        return destination
    }

    private func isInstalledFile(_ model: DownloadableModel) -> Bool {
        guard let directory = try? modelsDirectory() else { return false }
        return fileManager.fileExists(
            atPath: directory.appending(path: model.fileName).path
        )
    }

    private func checkAvailableCapacity(requiredBytes: Int64) throws {
        let directory = try appSupportDirectory()
        if let available = try capacityProvider.availableCapacity(at: directory),
            available < requiredBytes + Self.capacityHeadroom {
            throw DownloadError.insufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: available
            )
        }
    }

    private func appSupportDirectory() throws -> URL {
        if let baseDirectory {
            try fileManager.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )
            return baseDirectory
        }
        return try ModelLibrary.applicationSupportDirectory()
    }

    private func modelsDirectory() throws -> URL {
        let directory = try appSupportDirectory()
            .appending(path: "Models", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(directory)
        return directory
    }

    private func stagingDirectory() throws -> URL {
        let directory = try appSupportDirectory()
            .appending(path: "ModelDownloads", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(directory)
        return directory
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

nonisolated enum DownloadError: LocalizedError, Equatable {
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case missingFileMetadata(model: DownloadableModel)
    case invalidChecksum(model: DownloadableModel)
    case missingDownloadedFile

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let requiredBytes, let availableBytes):
            let required = requiredBytes.formatted(.byteCount(style: .file))
            let available = availableBytes.formatted(.byteCount(style: .file))
            return String(
                localized:
                    "There is not enough storage available. This download needs approximately \(required), but \(available) is available."
            )
        case .missingFileMetadata(let model):
            return String(
                localized:
                    "The download size for \(model.displayName) could not be determined."
            )
        case .invalidChecksum(let model):
            return String(
                localized:
                    "\(model.displayName) could not be verified. No downloaded file was kept."
            )
        case .missingDownloadedFile:
            return String(
                localized: "The downloaded model file could not be found."
            )
        }
    }
}
