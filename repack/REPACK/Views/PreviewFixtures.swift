import Foundation

extension AppModel {
    static var previewHome: AppModel {
        previewModel(phase: .ready)
    }

    static var previewNoModels: AppModel {
        AppModel()
    }

    static var previewUnloadedModel: AppModel {
        let model = previewModel(phase: .missingModel)
        model.modelURL = nil
        return model
    }

    static var previewLoadingModel: AppModel {
        previewModel(phase: .loadingModel)
    }

    static func previewProcessing(_ progress: PipelineProgress) -> AppModel {
        let model = previewModel(phase: .processing)
        model.progress = progress
        model.selectedImageURL = previewImageURL
        return model
    }

    static var previewOutput: AppModel {
        previewOutput(sampleAtomizationStatus: .parsed)
    }

    static var previewOutputWithAtomizationWarning: AppModel {
        previewOutput(sampleAtomizationStatus: .unparseable)
    }

    private static func previewOutput(
        sampleAtomizationStatus: AtomizationStatus
    ) -> AppModel {
        let model = previewModel(phase: .output)
        model.selectedImageURL = previewImageURL
        model.threshold = 0.5
        let captions = [
            CaptionSample(
                index: 0,
                kind: .reference,
                text: "A red can with a white logo sits on a wooden table."
            ),
            CaptionSample(
                index: 1,
                kind: .sample,
                text: "A red can is on a table."
            )
        ]
        model.result = CaptionResult(
            captions: captions,
            atomizedCaptions: [
                AtomizedCaption(
                    caption: captions[0],
                    statements: ["A red can is visible."],
                    status: .parsed
                ),
                AtomizedCaption(
                    caption: captions[1],
                    statements: sampleAtomizationStatus == .parsed
                        ? ["A red can is on a table."]
                        : [],
                    status: sampleAtomizationStatus
                )
            ],
            scoredAtomics: [
                ScoredAtomic(
                    index: 0,
                    statement: "A red can is visible.",
                    matches: [
                        AtomicMatch(
                            sampleIndex: 1,
                            statement: "A red can is on a table.",
                            score: 0.8
                        )
                    ],
                    averageScore: 0.8
                )
            ],
            retainedAtomics: ["A red can is visible."],
            caption: "A red can is visible.",
            threshold: 0.5,
            timings: [
                StageTiming(stage: .sampling, duration: .seconds(4.2)),
                StageTiming(stage: .atomizing, duration: .seconds(2.1)),
                StageTiming(stage: .scoring, duration: .milliseconds(20)),
                StageTiming(stage: .repackaging, duration: .seconds(0.8))
            ]
        )
        return model
    }

    static var previewInterrupted: AppModel {
        let model = previewModel(
            phase: .interrupted(
                String(
                    localized:
                        "Captioning did not finish. Restart Captioning to begin again from the start."
                )
            )
        )
        model.selectedImageURL = previewImageURL
        return model
    }

    static var previewImageURL: URL {
        URL(fileURLWithPath: "/tmp/repack-preview-image.png")
    }

    static func previewModel(phase: Phase) -> AppModel {
        let model = AppModel()
        let modelURL = URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm")
        let verificationModelURL = URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm")
        model.modelURL = modelURL
        model.localModels = [
            LocalModel(url: modelURL, isBundled: false),
            LocalModel(url: verificationModelURL, isBundled: false)
        ]
        model.phase = phase
        return model
    }
}
