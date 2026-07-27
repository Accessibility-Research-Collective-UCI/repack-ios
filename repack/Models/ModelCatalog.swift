import Foundation

nonisolated enum DownloadableModel:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Sendable {
    case e2b
    case e4b

    var id: Self { self }

    var displayName: String {
        switch self {
        case .e2b:
            String(localized: "Gemma 4 E2B")
        case .e4b:
            String(localized: "Gemma 4 E4B")
        }
    }

    var shortDescription: String {
        switch self {
        case .e2b:
            String(localized: "Runs on your device. Fastest captions.")
        case .e4b:
            String(
                localized:
                    "Runs on your device. Better captions, but slower. Gemma 4 E2B is also needed."
            )
        }
    }

    var executionLocation: ModelExecutionLocation {
        .onDevice
    }

    var descriptor: ModelDescriptor {
        switch self {
        case .e2b:
            ModelDescriptor(
                model: self,
                repositoryNamespace: "litert-community",
                repositoryName: "gemma-4-E2B-it-litert-lm",
                revision: "9262660a1676eed6d0c477ab1a86344430854664",
                fileName: "gemma-4-E2B-it.litertlm",
                xetHash: "ee3c29acd58e68bea04006a144cd2e40b3b34dcf5c08200a013744c518b15115",
                sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
                dependencies: []
            )
        case .e4b:
            ModelDescriptor(
                model: self,
                repositoryNamespace: "litert-community",
                repositoryName: "gemma-4-E4B-it-litert-lm",
                revision: "f7ad3343bd6ebc9607f4dc3bc4f2398bd5749bc5",
                fileName: "gemma-4-E4B-it.litertlm",
                xetHash: "7301453651814b29d434ca0d341e365e0e28dc811cb764d836995cae25b37f31",
                sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
                dependencies: [.e2b]
            )
        }
    }

    var fileName: String {
        descriptor.fileName
    }

    init?(modelURL: URL) {
        let identifier = modelURL.deletingPathExtension().lastPathComponent.lowercased()

        if identifier.contains("e2b") {
            self = .e2b
        } else if identifier.contains("e4b") {
            self = .e4b
        } else {
            return nil
        }
    }

    static func displayName(for modelURL: URL) -> String {
        DownloadableModel(modelURL: modelURL)?.displayName
            ?? String(localized: "Imported Model")
    }

    static func shortDescription(for modelURL: URL) -> String {
        DownloadableModel(modelURL: modelURL)?.shortDescription
            ?? String(localized: "Runs on your device")
    }

    static func executionLocation(for modelURL: URL) -> ModelExecutionLocation {
        DownloadableModel(modelURL: modelURL)?.executionLocation ?? .onDevice
    }

    var dependencyOrder: [DownloadableModel] {
        var ordered: [DownloadableModel] = []
        var visited = Set<DownloadableModel>()

        func append(_ model: DownloadableModel) {
            guard visited.insert(model).inserted else { return }
            model.descriptor.dependencies.forEach(append)
            ordered.append(model)
        }

        append(self)
        return ordered
    }
}

nonisolated struct ModelDescriptor: Identifiable, Equatable, Sendable {
    let model: DownloadableModel
    let repositoryNamespace: String
    let repositoryName: String
    let revision: String
    let fileName: String
    let xetHash: String
    let sha256: String
    let dependencies: [DownloadableModel]

    var id: DownloadableModel { model }
}

nonisolated struct DownloadFile: Identifiable, Equatable, Sendable {
    let descriptor: ModelDescriptor
    let byteCount: Int64

    var id: DownloadableModel { descriptor.model }
    var model: DownloadableModel { descriptor.model }
}

nonisolated enum DownloadPolicy: Equatable, Sendable {
    case install
    case validateAndRemove
}

nonisolated struct DownloadPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestedModel: DownloadableModel
    let files: [DownloadFile]
    let dependencyAlreadyInstalled: Bool
    let policy: DownloadPolicy

    init(
        id: UUID = UUID(),
        requestedModel: DownloadableModel,
        files: [DownloadFile],
        dependencyAlreadyInstalled: Bool,
        policy: DownloadPolicy
    ) {
        self.id = id
        self.requestedModel = requestedModel
        self.files = files
        self.dependencyAlreadyInstalled = dependencyAlreadyInstalled
        self.policy = policy
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var formattedTotalSize: String {
        totalBytes.formatted(.byteCount(style: .file))
    }

    var confirmationTitle: String {
        String(localized: "Download \(requestedModel.displayName)?")
    }

    var confirmationMessage: String {
        if requestedModel == .e4b, files.contains(where: { $0.model == .e2b }) {
            if policy == .validateAndRemove {
                return String(
                    localized:
                        "DEBUG: Gemma 4 E4B also requires Gemma 4 E2B. Both models will be downloaded in order and temporarily use approximately \(formattedTotalSize). The downloaded test files will be deleted after validation."
                )
            }
            return String(
                localized:
                    "Gemma 4 E4B also requires Gemma 4 E2B. Both models will be downloaded in order and use approximately \(formattedTotalSize) on this iPhone."
            )
        }

        if requestedModel == .e4b, dependencyAlreadyInstalled {
            return String(
                localized:
                    "Gemma 4 E2B is already downloaded. Gemma 4 E4B will use approximately \(formattedTotalSize) on this iPhone."
            )
        }

        if policy == .validateAndRemove {
            return String(
                localized:
                    "DEBUG: This download will temporarily use approximately \(formattedTotalSize). The downloaded test file will be deleted after validation."
            )
        }

        return String(
            localized:
                "This download will use approximately \(formattedTotalSize) on this iPhone."
        )
    }
}

nonisolated struct DownloadProgress: Equatable, Sendable {
    let requestedModel: DownloadableModel
    let currentModel: DownloadableModel
    let fileIndex: Int
    let fileCount: Int
    let completedBytes: Int64
    let totalBytes: Int64

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    var currentFileDescription: String {
        if fileCount > 1 {
            return String(
                localized:
                    "Downloading \(fileIndex) of \(fileCount): \(currentModel.displayName)"
            )
        }
        return String(localized: "Downloading \(currentModel.displayName)")
    }

    var accessibilityValue: String {
        let percentage = fractionCompleted.formatted(
            .percent.precision(.fractionLength(0))
        )
        if fileCount > 1 {
            return String(
                localized:
                    "Downloading \(fileIndex) of \(fileCount), \(currentModel.displayName), \(percentage)"
            )
        }
        return String(
            localized: "Downloading \(currentModel.displayName), \(percentage)"
        )
    }
}

nonisolated enum DownloadOutcome: Equatable, Sendable {
    case installed(URL)
    case validatedAndRemoved
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
