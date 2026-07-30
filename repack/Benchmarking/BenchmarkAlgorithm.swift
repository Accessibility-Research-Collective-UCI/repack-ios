#if BENCHMARKING
import Foundation

nonisolated enum BenchmarkAlgorithm: String, Codable, CaseIterable, Identifiable, Sendable {
    case repack = "REPACK"
    case capmas = "CapMAS"

    var id: Self { self }

    var title: String { rawValue }

    var stages: [BenchmarkStage] {
        switch self {
        case .repack:
            [
                BenchmarkStage(id: "sampling", title: "Sampling"),
                BenchmarkStage(id: "atomization", title: "Atomization"),
                BenchmarkStage(id: "scoring", title: "Scoring"),
                BenchmarkStage(id: "repacking", title: "Repacking")
            ]
        case .capmas:
            [
                BenchmarkStage(id: "captioning", title: "Captioning"),
                BenchmarkStage(id: "decomposition", title: "Decomposition"),
                BenchmarkStage(id: "verification", title: "Verification"),
                BenchmarkStage(id: "correction", title: "Correction")
            ]
        }
    }
}

nonisolated struct BenchmarkStage: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
}

nonisolated enum BenchmarkAlgorithmConfiguration: Equatable, Sendable {
    case repack(REPACKBenchmarkConfiguration)
    case capmas
}

nonisolated struct REPACKBenchmarkConfiguration: Equatable, Sendable {
    var sampleCount: Int
    var scoringMetric: ScoringMetric

    var similarityThreshold: Double {
        scoringMetric.threshold.defaultValue
    }

    static let `default` = REPACKBenchmarkConfiguration(
        sampleCount: 5,
        scoringMetric: .bleu
    )
}
#endif
