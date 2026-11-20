#if BENCHMARKING
import Foundation

@MainActor
final class REPACKBenchmarkExecutor: BenchmarkAlgorithmExecuting {
    private let prompt: CaptionPrompt
    private let configuration: REPACKBenchmarkConfiguration
    private let pipeline: REPACKPipeline

    init(
        visionModelURL: URL,
        textModelURL: URL,
        prompt: CaptionPrompt,
        configuration: REPACKBenchmarkConfiguration,
        embeddingResources: EmbeddingModelResources?,
        calibration: IDFCalibration?,
        engineFactory: any EngineFactory,
        devicePolicy: DevicePolicy
    ) async throws {
        self.prompt = prompt
        self.configuration = configuration
        let embeddingProvider = embeddingResources.map {
            EmbeddingGemmaService(
                resources: $0,
                calibration: calibration
            )
        }
        pipeline = try await REPACKPipeline(
            samplingModelURL: visionModelURL,
            processingModelURL: textModelURL,
            engineFactory: engineFactory,
            devicePolicy: devicePolicy,
            embeddingProvider: embeddingProvider
        )
    }

    func process(
        image: URL,
        progress: @escaping @MainActor (BenchmarkAlgorithmProgress) -> Void
    ) async throws -> BenchmarkImageExecutionResult {
        let result = try await pipeline.process(
            image: image,
            samplePrompt: prompt,
            sampleCount: configuration.sampleCount,
            threshold: configuration.similarityThreshold,
            scoringMetric: configuration.scoringMetric
        ) { pipelineProgress in
            progress(Self.benchmarkProgress(from: pipelineProgress))
        }

        let stageDurations = Dictionary(
            uniqueKeysWithValues: result.timings.map {
                (Self.key(for: $0.stage), $0.duration.benchmarkSeconds)
            }
        )
        let timing = BenchmarkImageTiming(
            file: image.lastPathComponent,
            totalTime: stageDurations.values.reduce(0, +),
            stages: stageDurations
        )
        return BenchmarkImageExecutionResult(
            timing: timing,
            metadata: BenchmarkImageMetadata(
                file: image.lastPathComponent,
                details: .repack(Self.metadata(from: result))
            )
        )
    }

    func cancel() async {
        await pipeline.cancel()
    }

    private static func benchmarkProgress(
        from progress: PipelineProgress
    ) -> BenchmarkAlgorithmProgress {
        let stage: BenchmarkStage? = switch progress {
        case .preparingVisionModel, .preparingTextModel:
            nil
        case .sampling:
            BenchmarkStage(id: "sampling", title: "Sampling")
        case .atomizing:
            BenchmarkStage(id: "atomization", title: "Atomization")
        case .scoring:
            BenchmarkStage(id: "scoring", title: "Scoring")
        case .repackaging:
            BenchmarkStage(id: "repacking", title: "Repacking")
        }
        return BenchmarkAlgorithmProgress(
            stage: stage,
            fractionCompleted: progress.fractionCompleted
        )
    }

    private static func key(for stage: PipelineStage) -> String {
        switch stage {
        case .sampling: "sampling"
        case .atomizing: "atomization"
        case .scoring: "scoring"
        case .repackaging: "repacking"
        }
    }

    private static func metadata(from result: CaptionResult) -> REPACKBenchmarkMetadata {
        let atomicsByCaption = Dictionary(
            uniqueKeysWithValues: result.atomizedCaptions.map {
                ($0.caption.index, $0.statements)
            }
        )
        return REPACKBenchmarkMetadata(
            captions: result.captions.map {
                BenchmarkCaptionMetadata(
                    index: $0.index,
                    type: $0.kind == .reference ? .reference : .sample,
                    text: $0.text,
                    atomics: atomicsByCaption[$0.index] ?? []
                )
            },
            scoredAtomics: result.scoredAtomics.map {
                BenchmarkAtomicMetadata(
                    statement: $0.statement,
                    averageScore: $0.averageScore,
                    matches: $0.matches.map {
                        BenchmarkAtomicMatch(
                            sampleIndex: $0.sampleIndex,
                            statement: $0.statement,
                            score: $0.score
                        )
                    }
                )
            },
            retainedAtomics: result.retainedAtomics,
            finalCaption: result.caption
        )
    }
}
#endif
