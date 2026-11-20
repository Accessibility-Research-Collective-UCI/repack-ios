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

nonisolated struct BenchmarkSettings: Encodable, Equatable, Sendable {
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
    var bertScore: BERTScoreExportSettings?
}

nonisolated struct BERTScoreExportSettings: Codable, Equatable, Sendable {
    let implementation: String
    let modelArtifact: String
    let calibrationFile: String?
}

nonisolated enum BenchmarkAlgorithmSettings: Encodable, Equatable, Sendable {
    case repack(REPACKExportSettings)
    case capmas
    case taco

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case similarityMetric
        case similarityThreshold
        case bertScore
        case verificationThreshold
        case classificationMethod
        case note
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
            try container.encodeIfPresent(settings.bertScore, forKey: .bertScore)
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
        case .taco:
            try container.encode(BenchmarkAlgorithm.taco, forKey: .algorithm)
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
                        similarityThreshold: settings.similarityThreshold,
                        bertScore: settings.scoringMetric == .semanticSimilarity
                            ? BERTScoreExportSettings(
                                implementation: "bertscore-f1-idf-layer16-v1",
                                modelArtifact: EmbeddingModelResources.modelFilename,
                                calibrationFile: (try? IDFCalibration.resolve(
                                    visionModel: visionModel.url, textModel: textModel.url
                                ))?.filename
                            ) : nil
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
        case .taco(let sampleCount):
            BenchmarkSettings(
                visionEngine: .vision(model: visionModel.choice),
                textEngine: .text(model: textModel.choice),
                numSamples: sampleCount,
                cooldownSeconds: cooldownSeconds,
                algorithmSettings: .taco,
                prompt: prompt
            )
        }
    }
}
#endif
