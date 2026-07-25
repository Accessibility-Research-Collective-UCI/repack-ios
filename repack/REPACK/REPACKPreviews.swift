import SwiftUI

#Preview("Home") {
    NavigationStack {
        REPACKHomeView(
            model: .previewHome,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {}
        )
    }
}

#Preview("Home · Dark · Accessibility") {
    NavigationStack {
        REPACKHomeView(
            model: .previewHome,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {}
        )
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Home · Interrupted") {
    NavigationStack {
        REPACKHomeView(
            model: .previewInterrupted,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {}
        )
    }
}

#Preview("Generating Captions") {
    NavigationStack {
        REPACKRunView(
            model: .previewProcessing(.sampling(completed: 2, total: 6)),
            restartAction: {},
            resetAction: {}
        )
    }
}

#Preview("Breaking Down Captions") {
    NavigationStack {
        REPACKRunView(
            model: .previewProcessing(.atomizing(completed: 2, total: 6)),
            restartAction: {},
            resetAction: {}
        )
    }
}

#Preview("Processing · Accessibility") {
    NavigationStack {
        REPACKRunView(
            model: .previewProcessing(.sampling(completed: 2, total: 6)),
            restartAction: {},
            resetAction: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Output") {
    NavigationStack {
        REPACKRunView(model: .previewOutput, restartAction: {}, resetAction: {})
    }
}

#Preview("Output · Accessibility") {
    NavigationStack {
        REPACKRunView(model: .previewOutput, restartAction: {}, resetAction: {})
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Interrupted Caption") {
    NavigationStack {
        REPACKRunView(
            model: .previewInterrupted,
            restartAction: {},
            resetAction: {}
        )
    }
}

private extension REPACKViewModel {
    static var previewHome: REPACKViewModel {
        previewModel(phase: .ready)
    }

    static func previewProcessing(_ progress: REPACKProgress) -> REPACKViewModel {
        let model = previewModel(phase: .processing)
        model.progress = progress
        model.selectedImageURL = previewImageURL
        return model
    }

    static var previewOutput: REPACKViewModel {
        let model = previewModel(phase: .output)
        model.selectedImageURL = previewImageURL
        model.threshold = 0.5
        model.result = REPACKResult(
            captions: [
                REPACKCaption(
                    index: 0,
                    kind: .reference,
                    text: "A red can with a white logo sits on a wooden table."
                ),
                REPACKCaption(
                    index: 1,
                    kind: .sample,
                    text: "A red can is on a table."
                )
            ],
            atomizedCaptions: [],
            scoredAtomics: [
                REPACKScoredAtomic(
                    index: 0,
                    statement: "A red can is visible.",
                    matches: [
                        REPACKAtomicMatch(
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
                REPACKStageTiming(stage: .sampling, duration: .seconds(4.2)),
                REPACKStageTiming(stage: .atomizing, duration: .seconds(2.1)),
                REPACKStageTiming(stage: .scoring, duration: .milliseconds(20)),
                REPACKStageTiming(stage: .repackaging, duration: .seconds(0.8))
            ]
        )
        return model
    }

    static var previewInterrupted: REPACKViewModel {
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

    static func previewModel(phase: Phase) -> REPACKViewModel {
        let model = REPACKViewModel()
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
