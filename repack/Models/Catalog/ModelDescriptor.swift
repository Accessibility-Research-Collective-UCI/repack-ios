import Foundation

nonisolated struct HuggingFaceModelSource: Equatable, Sendable {
    let namespace: String
    let name: String
    let revision: String
    let xetHash: String
}

nonisolated enum ModelSource: Equatable, Sendable {
    case huggingFace(HuggingFaceModelSource)
    case direct(URL)
}

nonisolated struct ModelDescriptor: Identifiable, Equatable, Sendable {
    let model: DownloadableModel
    let fileName: String
    let sha256: String
    let dependencies: [DownloadableModel]
    let source: ModelSource

    var id: String { fileName }
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
