import CryptoKit
import Foundation
import HuggingFace
import Xet

nonisolated protocol ModelHubDownloading: Sendable {
    func fileSize(for descriptor: ModelDescriptor) async throws -> Int64

    func download(
        _ descriptor: ModelDescriptor,
        byteCount: Int64,
        to destination: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL

    func cancelDownload() async
}

actor SwiftHuggingFaceModelHub: ModelHubDownloading {
    private let client: HubClient
    private var activeDownloader: XetDownloader?

    init(client: HubClient = HubClient(cache: nil)) {
        self.client = client
    }

    func fileSize(for descriptor: ModelDescriptor) async throws -> Int64 {
        let files = try await client.listFiles(
            in: repositoryID(for: descriptor),
            kind: .model,
            revision: descriptor.revision,
            recursive: true
        )
        guard
            let size = files.first(where: { $0.path == descriptor.fileName })?.size,
            size > 0
        else {
            throw DownloadError.missingFileMetadata(model: descriptor.model)
        }
        return Int64(size)
    }

    func download(
        _ descriptor: ModelDescriptor,
        byteCount: Int64,
        to destination: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let packageProgress = Progress(totalUnitCount: 0)
        let downloader = XetDownloader(
            refreshURL: xetRefreshURL(for: descriptor)
        )
        activeDownloader = downloader

        // TODO: Bind the determinate UI directly to Hugging Face Progress and
        // remove destination-size inference once
        // https://github.com/huggingface/swift-huggingface/issues/48 is fixed.
        let monitor = Task<Void, Never> {
            var lastReportedFraction = 0.0
            while !Task.isCancelled {
                let inferredFraction = Self.inferredProgress(
                    at: destination,
                    expectedByteCount: byteCount
                )
                let fraction = min(
                    max(inferredFraction, packageProgress.fractionCompleted),
                    0.999
                )
                if fraction > lastReportedFraction {
                    lastReportedFraction = fraction
                    await progressHandler(fraction)
                }

                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
        }

        // TODO: this is because swift-xet/swift-huggingface do not expose the downloader and prevents us from canceling in-progress downloads.
        // once fixed upstream, then use HubClient.downloadFile.
        do {
            _ = try await withTaskCancellationHandler {
                try await downloader.download(
                    descriptor.xetHash,
                    to: destination
                )
            } onCancel: { [weak self] in
                Task {
                    await self?.cancelDownload()
                }
            }
            try Task.checkCancellation()
            try await downloader.shutdown()
            activeDownloader = nil
            monitor.cancel()
            await monitor.value
            await progressHandler(1)
            return destination
        } catch {
            try? await downloader.shutdown()
            activeDownloader = nil
            monitor.cancel()
            await monitor.value
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    func cancelDownload() async {
        guard let activeDownloader else { return }
        self.activeDownloader = nil
        try? await activeDownloader.shutdown()
    }

    static func inferredProgress(
        at destination: URL,
        expectedByteCount: Int64,
        fileManager: FileManager = .default
    ) -> Double {
        guard expectedByteCount > 0,
            let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return min(max(Double(fileSize.int64Value) / Double(expectedByteCount), 0), 1)
    }

    private func repositoryID(
        for descriptor: ModelDescriptor
    ) -> Repo.ID {
        Repo.ID(
            namespace: descriptor.repositoryNamespace,
            name: descriptor.repositoryName
        )
    }

    private func xetRefreshURL(
        for descriptor: ModelDescriptor
    ) -> URL {
        URL(string: "https://huggingface.co")!
            .appending(path: "api")
            .appending(path: "models")
            .appending(path: descriptor.repositoryNamespace)
            .appending(path: descriptor.repositoryName)
            .appending(path: "xet-read-token")
            .appending(path: descriptor.revision)
    }
}
