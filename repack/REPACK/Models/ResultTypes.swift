import Foundation

nonisolated struct AtomicMatch: Equatable, Identifiable, Sendable {
    let sampleIndex: Int
    let statement: String?
    let score: Double

    var id: Int { sampleIndex }
}

nonisolated struct ScoredAtomic: Equatable, Identifiable, Sendable {
    let index: Int
    let statement: String
    let matches: [AtomicMatch]
    let averageScore: Double

    var id: Int { index }
}

nonisolated struct StageTiming: Equatable, Identifiable, Sendable {
    let stage: PipelineStage
    let duration: Duration

    var id: PipelineStage { stage }
}

nonisolated struct CaptionResult: Equatable, Sendable {
    let captions: [CaptionSample]
    let atomizedCaptions: [AtomizedCaption]
    let scoredAtomics: [ScoredAtomic]
    let retainedAtomics: [String]
    let caption: String
    let threshold: Double
    let scoringMetric: ScoringMetric
    let timings: [StageTiming]
    var embeddingDuration: Duration?

    func replacingRepackage(
        retainedAtomics: [String],
        caption: String,
        threshold: Double,
        duration: Duration
    ) -> CaptionResult {
        var updatedTimings = timings.filter { $0.stage != .repackaging }
        updatedTimings.append(StageTiming(stage: .repackaging, duration: duration))

        return CaptionResult(
            captions: captions,
            atomizedCaptions: atomizedCaptions,
            scoredAtomics: scoredAtomics,
            retainedAtomics: retainedAtomics,
            caption: caption,
            threshold: threshold,
            scoringMetric: scoringMetric,
            timings: updatedTimings,
            embeddingDuration: embeddingDuration
        )
    }
}
