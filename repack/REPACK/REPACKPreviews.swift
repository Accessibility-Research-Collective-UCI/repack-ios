import SwiftUI

#Preview("Home") {
    NavigationStack {
        REPACKHomeView(
            model: REPACKViewModel(),
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
            model: REPACKViewModel(),
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {}
        )
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Output") {
    NavigationStack {
        REPACKRunView(model: .previewOutput, resetAction: {})
    }
}

private extension REPACKViewModel {
    static var previewOutput: REPACKViewModel {
        let model = REPACKViewModel()
        model.phase = .output
        model.threshold = 0.75
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
            threshold: 0.75,
            timings: [
                REPACKStageTiming(stage: .sampling, duration: .seconds(4.2)),
                REPACKStageTiming(stage: .atomizing, duration: .seconds(2.1)),
                REPACKStageTiming(stage: .scoring, duration: .milliseconds(20)),
                REPACKStageTiming(stage: .repackaging, duration: .seconds(0.8))
            ]
        )
        return model
    }
}
