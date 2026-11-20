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

/// Captured once and reused when engines are recreated between images.
nonisolated struct ResolvedBenchmarkRun: Sendable {
    let request: BenchmarkRunRequest
    let visionSettings: InferenceEngineSettings
    let textSettings: InferenceEngineSettings
    let embeddingResources: EmbeddingModelResources?
    let calibration: IDFCalibration?

    init(
        request: BenchmarkRunRequest,
        visionSettings: InferenceEngineSettings,
        textSettings: InferenceEngineSettings,
        embeddingResources: EmbeddingModelResources?
    ) {
        self.request = request
        self.visionSettings = visionSettings
        self.textSettings = textSettings
        self.embeddingResources = embeddingResources
        if case .repack(let settings) = request.algorithmConfiguration,
           settings.scoringMetric == .semanticSimilarity {
            calibration = try? IDFCalibration.resolve(
                visionModel: request.visionModel.url, textModel: request.textModel.url
            )
        } else {
            calibration = nil
        }
    }
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
            try container.encode(CapMASBenchmarkExecutor.verificationThreshold, forKey: .verificationThreshold)
            try container.encode(
                CapMASBenchmarkExecutor.classificationMethod,
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

extension ResolvedBenchmarkRun {
    nonisolated var exportedSettings: BenchmarkSettings {
        let visionModel = request.visionModel
        let textModel = request.textModel
        let cooldownSeconds = request.cooldownSeconds
        let prompt = request.prompt
        return switch request.algorithmConfiguration {
        case .repack(let settings):
            BenchmarkSettings(
                visionEngine: .init(model: visionModel.choice, settings: visionSettings),
                textEngine: .init(model: textModel.choice, settings: textSettings),
                numSamples: settings.sampleCount,
                cooldownSeconds: cooldownSeconds,
                algorithmSettings: .repack(
                    REPACKExportSettings(
                        similarityMetric: settings.scoringMetric,
                        similarityThreshold: settings.similarityThreshold,
                        bertScore: settings.scoringMetric == .semanticSimilarity
                            ? BERTScoreExportSettings(
                                implementation: SemanticCaptionScorer.implementation,
                                modelArtifact: embeddingResources?.modelURL.lastPathComponent
                                    ?? EmbeddingModelResources.modelFilename,
                                calibrationFile: calibration?.filename
                            ) : nil
                    )
                ),
                prompt: prompt
            )
        case .capmas:
            BenchmarkSettings(
                visionEngine: .init(model: visionModel.choice, settings: visionSettings),
                textEngine: .init(model: textModel.choice, settings: textSettings),
                numSamples: CapMASBenchmarkExecutor.sampleCount,
                cooldownSeconds: cooldownSeconds,
                algorithmSettings: .capmas,
                prompt: prompt
            )
        case .taco(let sampleCount):
            BenchmarkSettings(
                visionEngine: .init(model: visionModel.choice, settings: visionSettings),
                textEngine: .init(model: textModel.choice, settings: textSettings),
                numSamples: sampleCount,
                cooldownSeconds: cooldownSeconds,
                algorithmSettings: .taco,
                prompt: prompt
            )
        }
    }
}
#endif
