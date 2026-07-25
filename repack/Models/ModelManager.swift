import Foundation

struct LocalModel: Identifiable, Equatable {
    let url: URL
    let isBundled: Bool

    nonisolated var id: String { url.path }
    nonisolated var displayName: String {
        DownloadableModel.displayName(for: url)
    }
    nonisolated var detail: String {
        DownloadableModel.shortDescription(for: url)
    }
}

enum DownloadableModel: String, CaseIterable, Identifiable {
    case e2b
    case e4b

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .e2b:
            String(localized: "Gemma 4 E2B")
        case .e4b:
            String(localized: "Gemma 4 E4B")
        }
    }

    nonisolated var shortDescription: String {
        switch self {
        case .e2b:
            String(localized: "Runs on your device. Fastest captions.")
        case .e4b:
            String(localized: "Runs on your device. Better captions, but slower. Gemma 4 E2B is also needed.")
        }
    }

    nonisolated var executionLocation: ModelExecutionLocation {
        .onDevice
    }

    nonisolated var approximateSize: String {
        switch self {
        case .e2b:
            "2.58 GB"
        case .e4b:
            "3.66 GB"
        }
    }

    nonisolated var repository: String {
        switch self {
        case .e2b:
            "litert-community/gemma-4-E2B-it-litert-lm"
        case .e4b:
            "litert-community/gemma-4-E4B-it-litert-lm"
        }
    }

    nonisolated var fileName: String {
        switch self {
        case .e2b:
            "gemma-4-E2B-it.litertlm"
        case .e4b:
            "gemma-4-E4B-it.litertlm"
        }
    }

    nonisolated var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)")!
    }

    nonisolated init?(modelURL: URL) {
        let identifier = modelURL.deletingPathExtension().lastPathComponent.lowercased()

        if identifier.contains("e2b") {
            self = .e2b
        } else if identifier.contains("e4b") {
            self = .e4b
        } else {
            return nil
        }
    }

    nonisolated static func displayName(for modelURL: URL) -> String {
        DownloadableModel(modelURL: modelURL)?.displayName
            ?? String(localized: "Imported Model")
    }

    nonisolated static func shortDescription(for modelURL: URL) -> String {
        DownloadableModel(modelURL: modelURL)?.shortDescription
            ?? String(localized: "Runs on your device")
    }

    nonisolated static func executionLocation(for modelURL: URL) -> ModelExecutionLocation {
        DownloadableModel(modelURL: modelURL)?.executionLocation ?? .onDevice
    }
}

nonisolated enum ModelExecutionLocation: Sendable {
    case onDevice

    var progressDescription: String {
        switch self {
        case .onDevice:
            String(localized: "on device")
        }
    }
}

struct ModelManager {
    private let storedModelPathKey = "GemmaModelPath"
    private let modelExtension = "litertlm"
    private let bundledModelNames = [
        "gemma-4-E2B-it",
        "gemma-4-E4B-it"
    ]

    func refreshLocalModels(currentModelURL: URL?) -> (models: [LocalModel], selectedModelURL: URL?) {
        let models = localModels()
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

    func importModel(from selectedURL: URL) async throws -> URL {
        try await Self.copyModelIntoAppSupport(selectedURL)
    }

    func download(
        model: DownloadableModel,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let destinationDirectory = try Self.modelsDirectory()
        let destinationURL = destinationDirectory.appendingPathComponent(model.fileName)
        let temporaryURL = destinationDirectory.appendingPathComponent("\(model.fileName).download")

        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }

        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
        }

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        let expectedLength = httpResponse.expectedContentLength
        var receivedLength: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1024 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            receivedLength += 1

            if buffer.count >= 1024 * 1024 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                if expectedLength > 0 {
                    await progressHandler(min(Double(receivedLength) / Double(expectedLength), 1))
                }
            }
        }

        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        await progressHandler(1)
        return destinationURL
    }

    private func localModels() -> [LocalModel] {
        var models = (Bundle.main.urls(forResourcesWithExtension: modelExtension, subdirectory: nil) ?? [])
            .map { LocalModel(url: $0, isBundled: true) }

        models += bundledModelNames.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: modelExtension).map {
                LocalModel(url: $0, isBundled: true)
            }
        }

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

    private static func copyModelIntoAppSupport(_ sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationDirectory = try modelsDirectory()
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }.value
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
