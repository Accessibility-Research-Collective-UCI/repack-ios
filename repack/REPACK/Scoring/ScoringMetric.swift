import Foundation

nonisolated struct ThresholdConfiguration: Equatable, Sendable {
    let range: ClosedRange<Double>
    let defaultValue: Double
    let tickSpacing: Double
    let adjustment: Double

    var ticks: [Double] {
        let count = Int(
            ((range.upperBound - range.lowerBound) / tickSpacing).rounded()
        )
        return (0...count).map {
            range.lowerBound + Double($0) * tickSpacing
        }
    }

    func normalized(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let rounded = (clamped / adjustment).rounded() * adjustment
        return min(max(rounded, range.lowerBound), range.upperBound)
    }
}

nonisolated struct ScoreRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double?

    func contains(_ score: Double) -> Bool {
        score >= minimum && (maximum.map { score < $0 } ?? true)
    }
}

nonisolated enum StratificationTier: CaseIterable, Hashable, Identifiable, Sendable {
    case relativelyCertain
    case somewhatSure
    case highlyUncertain

    var id: Self { self }

    var leadIn: String {
        switch self {
        case .relativelyCertain:
            String(localized: "We are relatively certain that…")
        case .somewhatSure:
            String(localized: "We are somewhat sure that…")
        case .highlyUncertain:
            String(localized: "Finally, we are highly uncertain about…")
        }
    }

    var emptyMessage: String? {
        switch self {
        case .relativelyCertain:
            String(localized: "There is no information here that we are relatively certain about.")
        case .somewhatSure:
            nil
        case .highlyUncertain:
            String(localized: "There is no information which we think is highly unlikely.")
        }
    }
}

nonisolated struct StratificationCalibration: Equatable, Sendable {
    let ranges: [StratificationTier: ScoreRange]

    func range(for tier: StratificationTier) -> ScoreRange {
        guard let range = ranges[tier] else {
            preconditionFailure("Missing stratification range for \(tier).")
        }
        return range
    }
}

nonisolated enum ScoringMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case bleu
    case semanticSimilarity

    var id: Self { self }

    var title: String {
        switch self {
        case .bleu:
            String(localized: "Lexical Similarity")
        case .semanticSimilarity:
            String(localized: "Semantic Similarity")
        }
    }

    var description: String {
        switch self {
        case .bleu:
            String(localized: "Using word overlap to select information from image description.")
        case .semanticSimilarity:
            String(localized: "Using meaning-based overlap to select information from image description.")
        }
    }

    var scoreLabel: String {
        switch self {
        case .bleu:
            String(localized: "Lexical average")
        case .semanticSimilarity:
            String(localized: "Semantic average")
        }
    }

    var generationDetailsName: String {
        switch self {
        case .bleu:
            String(localized: "Lexical Similarity (BLEU-1)")
        case .semanticSimilarity:
            String(localized: "Semantic Similarity (Embedding Gemma 300)")
        }
    }

    var threshold: ThresholdConfiguration {
        switch self {
        case .bleu:
            ThresholdConfiguration(
                range: 0...1,
                defaultValue: 0.5,
                tickSpacing: 0.1,
                adjustment: 0.01
            )
        case .semanticSimilarity:
            ThresholdConfiguration(
                range: 0.6...1,
                defaultValue: 0.75,
                tickSpacing: 0.05,
                adjustment: 0.01
            )
        }
    }

    func stratificationCalibration(
        for model: DownloadableModel
    ) -> StratificationCalibration {
        guard let calibration = stratificationCalibrations[model] else {
            preconditionFailure("Missing stratification calibration for \(model).")
        }
        return calibration
    }

    private var stratificationCalibrations: [DownloadableModel: StratificationCalibration] {
        switch self {
        case .bleu:
            [
                .e2b: StratificationCalibration(
                    ranges: [
                        .relativelyCertain: ScoreRange(minimum: 0.95, maximum: nil),
                        .somewhatSure: ScoreRange(minimum: 0.7, maximum: 0.95),
                        .highlyUncertain: ScoreRange(minimum: 0, maximum: 0.7)
                    ]
                ),
                .e4b: StratificationCalibration(
                    ranges: [
                        .relativelyCertain: ScoreRange(minimum: 0.95, maximum: nil),
                        .somewhatSure: ScoreRange(minimum: 0.7, maximum: 0.95),
                        .highlyUncertain: ScoreRange(minimum: 0, maximum: 0.7)
                    ]
                )
            ]
        case .semanticSimilarity:
            [
                .e2b: StratificationCalibration(
                    ranges: [
                        .relativelyCertain: ScoreRange(minimum: 0.9, maximum: nil),
                        .somewhatSure: ScoreRange(minimum: 0.8, maximum: 0.9),
                        .highlyUncertain: ScoreRange(minimum: 0, maximum: 0.8)
                    ]
                ),
                .e4b: StratificationCalibration(
                    ranges: [
                        .relativelyCertain: ScoreRange(minimum: 0.9, maximum: nil),
                        .somewhatSure: ScoreRange(minimum: 0.8, maximum: 0.9),
                        .highlyUncertain: ScoreRange(minimum: 0, maximum: 0.8)
                    ]
                )
            ]
        }
    }

}
