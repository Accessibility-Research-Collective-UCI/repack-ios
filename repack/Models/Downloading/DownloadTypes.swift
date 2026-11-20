import Foundation

nonisolated struct DownloadFile: Identifiable, Equatable, Sendable {
    let descriptor: ModelDescriptor
    let byteCount: Int64

    var id: String { descriptor.fileName }
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
        if requestedModel == .embeddingGemma {
            if policy == .validateAndRemove {
                return String(
                    localized:
                        "DEBUG: Embedding Gemma, its tokenizer, and IDF calibrations will be downloaded and validated, temporarily using approximately \(formattedTotalSize). The downloaded test files will be deleted after validation."
                )
            }
            return String(
                localized:
                    "Embedding Gemma, its tokenizer, and IDF calibrations will use approximately \(formattedTotalSize) on this iPhone."
            )
        }

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
