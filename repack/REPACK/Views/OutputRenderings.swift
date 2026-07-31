import SwiftUI

struct OutputRenderings: View {
    @Bindable var model: AppModel
    let result: CaptionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker(
                "Output rendering",
                selection: Binding(
                    get: { model.outputRenderings.selection },
                    set: { model.selectOutputRendering($0) }
                )
            ) {
                ForEach(OutputRenderingsController.Rendering.allCases) { rendering in
                    Text(rendering.title).tag(rendering)
                }
            }
            .pickerStyle(.segmented)

            rendering
        }
    }

    @ViewBuilder
    private var rendering: some View {
        switch model.outputRenderings.selection {
        case .repack:
            RepackOutput(result: result, isRegenerating: model.isRegenerating)
            thresholdControl
        case .atomic:
            AtomicListOutput(result: result, threshold: model.threshold)
            thresholdControl
        case .hedged:
            HedgedOutput(
                result: result,
                hedgedCaption: model.outputRenderings.hedgedCaption,
                isGenerating: model.outputRenderings.isGenerating,
                errorMessage: model.outputRenderings.errorMessage,
                retry: model.retryOutputRendering
            )
            thresholdControl
        case .stratified:
            StratifiedOutput(
                result: result,
                model: model.selectedCaptioningModel,
                captions: model.outputRenderings.stratifiedCaptions,
                isGenerating: model.outputRenderings.isGenerating,
                errorMessage: model.outputRenderings.errorMessage,
                retry: model.retryOutputRendering
            )
        }
    }

    private var thresholdControl: some View {
        SimilarityThresholdControl(
            metric: result.scoringMetric,
            value: model.threshold,
            onChange: model.updateThreshold
        )
    }
}

private struct RepackOutput: View {
    let result: CaptionResult
    let isRegenerating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.caption)
                .font(.title2)
                .textSelection(.enabled)
                .accessibilityLabel("Result: \(result.caption)")

            if isRegenerating {
                HStack {
                    ProgressView()
                    Text("Updating caption…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 20))
    }
}

private struct AtomicListOutput: View {
    let result: CaptionResult
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            atomicSection("Included", atomics: included, emptyMessage: "No atomic statements are included at this threshold.")
            atomicSection("Removed", atomics: removed, emptyMessage: "No atomic statements are removed at this threshold.")
        }
    }

    private var included: [ScoredAtomic] {
        result.scoredAtomics.filter { $0.averageScore >= threshold }
    }

    private var removed: [ScoredAtomic] {
        result.scoredAtomics.filter { $0.averageScore < threshold }
    }

    @ViewBuilder
    private func atomicSection(
        _ title: LocalizedStringKey,
        atomics: [ScoredAtomic],
        emptyMessage: LocalizedStringKey
    ) -> some View {
        DetailSection(title) {
            if atomics.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(atomics) { atomic in
                        Text(atomic.statement)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct HedgedOutput: View {
    let result: CaptionResult
    let hedgedCaption: String?
    let isGenerating: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.caption)
                .font(.title2)
                .textSelection(.enabled)

            if isGenerating {
                ProgressView("Generating hedged caption")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Hedged Caption Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else if let hedgedCaption {
                Text(hedgedCaption)
                    .textSelection(.enabled)
            } else {
                Text("No additional uncertain details at this threshold.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 20))
    }
}

private struct StratifiedOutput: View {
    let result: CaptionResult
    let model: DownloadableModel
    let captions: [StratificationTier: String]
    let isGenerating: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Based on our calibration of this model…")
                .font(.headline)

            if isGenerating {
                ProgressView("Generating stratified captions")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Stratified Captions Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else {
                ForEach(StratificationTier.allCases) { tier in
                    tierSection(tier)
                }
            }
        }
    }

    @ViewBuilder
    private func tierSection(_ tier: StratificationTier) -> some View {
        let statements = statements(for: tier)
        if let caption = captions[tier] {
            tierContent(title: tier.leadIn) {
                Text(caption)
                    .textSelection(.enabled)
            }
        } else if statements.isEmpty, let emptyMessage = tier.emptyMessage {
            tierContent(title: tier.leadIn) {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tierContent<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statements(for tier: StratificationTier) -> [ScoredAtomic] {
        let calibration = result.scoringMetric.stratificationCalibration(for: model)
        return result.scoredAtomics.filter {
            calibration.range(for: tier).contains($0.averageScore)
        }
    }
}
