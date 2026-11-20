#if BENCHMARKING
import Foundation

nonisolated enum BenchmarkAlgorithm: String, Codable, CaseIterable, Identifiable, Sendable {
    case repack = "REPACK"
    case capmas = "CapMAS"
    case taco = "TACO"

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
        case .taco:
            [
                BenchmarkStage(id: "captioning", title: "Captioning"),
                BenchmarkStage(id: "tupleExtraction", title: "Tuple Extraction"),
                BenchmarkStage(id: "queryGeneration", title: "Query Generation"),
                BenchmarkStage(id: "reformulation", title: "Reformulation"),
                BenchmarkStage(id: "verification", title: "Verification"),
                BenchmarkStage(id: "refinement", title: "Refinement")
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
    case taco(sampleCount: Int)
}

nonisolated struct REPACKBenchmarkConfiguration: Equatable, Sendable {
    var sampleCount: Int
    var scoringMetric: ScoringMetric

    var similarityThreshold: Double {
        scoringMetric.threshold.defaultValue
    }

    static let `default` = REPACKBenchmarkConfiguration(
        sampleCount: 5,
        scoringMetric: .semanticSimilarity
    )
}
#endif
