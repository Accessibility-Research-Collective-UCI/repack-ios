import SwiftUI

#Preview("Home") {
    NavigationStack {
        HomeView(
            model: .previewHome,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
}

#Preview("Home · Dark · Accessibility") {
    NavigationStack {
        HomeView(
            model: .previewHome,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Home · No Models") {
    NavigationStack {
        HomeView(
            model: .previewNoModels,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
}

#Preview("Home · Model Available, Unselected") {
    NavigationStack {
        HomeView(
            model: .previewUnloadedModel,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
}

#Preview("Home · Loading Model") {
    NavigationStack {
        HomeView(
            model: .previewLoadingModel,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
}

#Preview("Home · Interrupted") {
    NavigationStack {
        HomeView(
            model: .previewInterrupted,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
}

#Preview("Home · Completed") {
    NavigationStack {
        HomeView(
            model: .previewOutput,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
}

#Preview("Home · Completed · Dark · Accessibility") {
    NavigationStack {
        HomeView(
            model: .previewOutput,
            selectedPhotoItem: .constant(nil),
            showCamera: .constant(false),
            showModelManager: .constant(false),
            captionAction: {},
            resultsAction: {}
        )
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Generating Captions") {
    NavigationStack {
        RunView(
            model: .previewProcessing(.sampling(completed: 2, total: 6)),
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
}

#Preview("Breaking Down Captions") {
    NavigationStack {
        RunView(
            model: .previewProcessing(.atomizing(completed: 2, total: 6)),
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
}

#Preview("Processing · Accessibility") {
    NavigationStack {
        RunView(
            model: .previewProcessing(.sampling(completed: 2, total: 6)),
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Processing · Dimmed") {
    ZStack {
        NavigationStack {
            RunView(
                model: .previewProcessing(.sampling(completed: 2, total: 6)),
                restartAction: {},
                cancelAction: {},
                resetAction: {}
            )
        }

        CaptioningDimOverlay(brightenAction: {})
    }
}

#Preview("Output") {
    NavigationStack {
        RunView(
            model: .previewOutput,
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
}

#Preview("Output · Semantic Similarity") {
    NavigationStack {
        RunView(
            model: .previewSemanticOutput,
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
}

#Preview("Output · Atomization Warning") {
    NavigationStack {
        RunView(
            model: .previewOutputWithAtomizationWarning,
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
}

#Preview("Output · Accessibility") {
    NavigationStack {
        RunView(
            model: .previewOutput,
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Interrupted Caption") {
    NavigationStack {
        RunView(
            model: .previewInterrupted,
            restartAction: {},
            cancelAction: {},
            resetAction: {}
        )
    }
}
