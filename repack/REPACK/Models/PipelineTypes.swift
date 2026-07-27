import Foundation

nonisolated enum CaptionPrompt: Equatable, Sendable {
    case product
    case describe
    case custom(String)

    var resolvedText: String {
        switch self {
        case .product:
            Prompts.productPrompt
        case .describe:
            Prompts.describePrompt
        case .custom(let prompt):
            prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

nonisolated enum PipelineStage: Equatable, Hashable, Sendable {
    case sampling
    case atomizing
    case scoring
    case repackaging
}

nonisolated enum PipelineProgress: Equatable, Sendable {
    case preparingVisionModel
    case sampling(completed: Int, total: Int)
    case preparingTextModel
    case atomizing(completed: Int, total: Int)
    case scoring(completed: Int, total: Int)
    case repackaging

    var counts: (completed: Int, total: Int)? {
        switch self {
        case .sampling(let completed, let total),
             .atomizing(let completed, let total),
             .scoring(let completed, let total):
            (completed, total)
        case .preparingVisionModel, .preparingTextModel, .repackaging:
            nil
        }
    }

    var fractionCompleted: Double? {
        guard let counts, counts.total > 0 else { return nil }
        return min(max(Double(counts.completed) / Double(counts.total), 0), 1)
    }
}

nonisolated struct CaptionSample: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case reference
        case sample
    }

    let index: Int
    let kind: Kind
    let text: String

    var id: Int { index }
}

nonisolated enum AtomizationStatus: Equatable, Sendable {
    case parsed
    case unparseable
}

nonisolated struct AtomizationResult: Equatable, Sendable {
    let statements: [String]
    let status: AtomizationStatus
}

nonisolated struct AtomizedCaption: Equatable, Identifiable, Sendable {
    let caption: CaptionSample
    let statements: [String]
    let status: AtomizationStatus

    var id: Int { caption.id }
}
