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

}
