#if BENCHMARKING
import Foundation

nonisolated enum BenchmarkPromptType: String, Codable, CaseIterable, Identifiable, Sendable {
    case product
    case describe
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .product: "Product"
        case .describe: "Describe"
        case .custom: "Custom"
        }
    }

    func prompt(customText: String) -> CaptionPrompt {
        switch self {
        case .product: .product
        case .describe: .describe
        case .custom: .custom(customText)
        }
    }
}

nonisolated struct BenchmarkPromptSettings: Codable, Equatable, Sendable {
    let type: BenchmarkPromptType
    let text: String
}

nonisolated struct BenchmarkRunRequest: Sendable {
    let algorithm: BenchmarkAlgorithm
    let visionModel: ResolvedBenchmarkModel
    let textModel: ResolvedBenchmarkModel
    let algorithmConfiguration: BenchmarkAlgorithmConfiguration
    let prompt: BenchmarkPromptSettings
    let cooldownSeconds: Int
}

nonisolated struct BenchmarkSettings: Codable, Equatable, Sendable {
    let visionEngine: BenchmarkEngineSettings
    let textEngine: BenchmarkEngineSettings
    let numSamples: Int
    let cooldownSeconds: Int
    let algorithmSettings: BenchmarkAlgorithmSettings
    let prompt: BenchmarkPromptSettings
}

nonisolated struct REPACKExportSettings: Codable, Equatable, Sendable {
    let similarityMetric: ScoringMetric
    let similarityThreshold: Double
}

nonisolated enum BenchmarkAlgorithmSettings: Codable, Equatable, Sendable {
    case repack(REPACKExportSettings)
    case capmas

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case similarityMetric
        case similarityThreshold
        case verificationThreshold
        case classificationMethod
        case note
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(BenchmarkAlgorithm.self, forKey: .algorithm) {
        case .repack:
            self = .repack(
                REPACKExportSettings(
                    similarityMetric: try container.decode(
                        ScoringMetric.self,
                        forKey: .similarityMetric
                    ),
                    similarityThreshold: try container.decode(
                        Double.self,
                        forKey: .similarityThreshold
                    )
                )
            )
        case .capmas:
            self = .capmas
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repack(let settings):
            try container.encode(BenchmarkAlgorithm.repack, forKey: .algorithm)
            try container.encode(
                settings.similarityMetric,
                forKey: .similarityMetric
            )
            try container.encode(
                settings.similarityThreshold,
                forKey: .similarityThreshold
            )
        case .capmas:
            try container.encode(BenchmarkAlgorithm.capmas, forKey: .algorithm)
            try container.encode(0.5, forKey: .verificationThreshold)
            try container.encode(
                "randomBinary",
                forKey: .classificationMethod
            )
            try container.encode(
                "Random binary scores replace unavailable True/False token logits and are used only to preserve the latency workload. Do not use this output for quality evaluation.",
                forKey: .note
            )
        }
    }
}

extension BenchmarkRunRequest {
    nonisolated var exportedSettings: BenchmarkSettings {
        switch algorithmConfiguration {
        case .repack(let settings):
            BenchmarkSettings(
                visionEngine: .vision(model: visionModel.choice),
                textEngine: .text(model: textModel.choice),
                numSamples: settings.sampleCount,
                cooldownSeconds: cooldownSeconds,
                algorithmSettings: .repack(
                    REPACKExportSettings(
                        similarityMetric: settings.scoringMetric,
                        similarityThreshold: settings.similarityThreshold
                    )
                ),
                prompt: prompt
            )
        case .capmas:
            BenchmarkSettings(
                visionEngine: .vision(model: visionModel.choice),
                textEngine: .text(model: textModel.choice),
                numSamples: 1,
                cooldownSeconds: cooldownSeconds,
                algorithmSettings: .capmas,
                prompt: prompt
            )
        }
    }
}
#endif
