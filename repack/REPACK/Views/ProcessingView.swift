import SwiftUI

struct ProcessingView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let fraction = model.progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .accessibilityLabel(title)
                    .accessibilityValue(progressValue)
            } else {
                ProgressView()
                    .accessibilityLabel(title)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let elapsed = model.elapsed {
                    LabeledContent("Elapsed", value: format(elapsed))
                        .monospacedDigit()
                }
            }
        }
    }

    private var title: String {
        switch model.progress {
        case .preparingVisionModel: String(localized: "Preparing vision model")
        case .sampling: String(localized: "Generating captions")
        case .preparingTextModel: String(localized: "Preparing text model")
        case .atomizing: String(localized: "Breaking down captions")
        case .scoring: String(localized: "Scoring similarities")
        case .repackaging: String(localized: "Repackaging caption")
        case nil: String(localized: "Preparing REPACK")
        }
    }

    private var progressValue: String {
        guard let progress = model.progress,
              let counts = progress.counts else {
            return ""
        }
        return switch progress {
        case .sampling, .atomizing:
            String(localized: "\(counts.completed) of \(counts.total) captions")
        case .scoring:
            String(localized: "\(counts.completed) of \(counts.total) statements")
        default:
            ""
        }
    }

    private var summary: String {
        let execution = executionLocation.progressDescription
        guard let progress = model.progress,
              let counts = progress.counts else {
            return String(localized: "Model: \(modelName), running \(execution)")
        }

        let remaining = max(counts.total - counts.completed, 0)
        switch progress {
        case .sampling, .atomizing:
            return String(
                localized:
                    "Model: \(modelName), running \(execution)\n\(remaining) of \(counts.total) captions remaining"
            )
        case .scoring:
            return String(
                localized:
                    "Model: \(modelName), running \(execution)\n\(remaining) of \(counts.total) statements remaining"
            )
        default:
            return String(localized: "Model: \(modelName), running \(execution)")
        }
    }

    private var modelName: String {
        switch model.progress {
        case .sampling, .preparingVisionModel, nil:
            model.selectedModelName
        case .scoring:
            model.scoringModelName
        case .atomizing, .preparingTextModel, .repackaging:
            model.verificationModelName
        }
    }

    private var executionLocation: ModelExecutionLocation {
        guard let modelURL = model.modelURL else {
            return .onDevice
        }
        switch model.progress {
        case .sampling, .preparingVisionModel, nil:
            return DownloadableModel.executionLocation(for: modelURL)
        case .scoring:
            return .onDevice
        case .atomizing, .preparingTextModel, .repackaging:
            guard let processingURL = ModelLibrary.processingModelURL(
                for: modelURL,
                availableModels: model.localModels
            ) else {
                return .onDevice
            }
            return DownloadableModel.executionLocation(for: processingURL)
        }
    }

    private func format(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.minutes, .seconds],
                width: .abbreviated,
                fractionalPart: .hide
            )
        )
    }
}
