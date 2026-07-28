import Foundation

nonisolated enum InstallationOrigin: String, Codable, Sendable {
    case bundled
    case approved
    case imported
}

nonisolated struct InstallationRecord: Codable, Equatable, Sendable {
    let fileName: String
    let origin: InstallationOrigin
    let model: DownloadableModel?
    var explicitlyOwned: Bool
    var requiredBy: Set<DownloadableModel>
    var byteCount: Int64
}

nonisolated struct LocalModel: Identifiable, Equatable, Sendable {
    let url: URL
    let isBundled: Bool
    let origin: InstallationOrigin

    init(
        url: URL,
        isBundled: Bool,
        origin: InstallationOrigin? = nil
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

nonisolated struct StorageItem: Identifiable, Equatable, Sendable {
    let model: LocalModel
    let record: InstallationRecord

    var id: String { model.id }
    var displayName: String { model.displayName }
    var byteCount: Int64 { record.byteCount }

    var originDescription: String {
        switch record.origin {
        case .approved:
            String(localized: "Downloaded")
        case .imported:
            String(localized: "Imported")
        case .bundled:
            String(localized: "Bundled with this Debug build")
        }
    }

    var dependencyDescription: String? {
        guard !record.requiredBy.isEmpty else { return nil }
        let names = record.requiredBy
            .map(\.displayName)
            .sorted()
            .formatted(.list(type: .and))
        return String(localized: "Required by \(names)")
    }
}

nonisolated struct DeletionPlan: Equatable, Sendable {
    let items: [StorageItem]

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
