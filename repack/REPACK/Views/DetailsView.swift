import SwiftUI

struct DetailsView: View {
    let result: CaptionResult
    let visionModelName: String
    let verificationModelName: String
    let prompt: String

    var body: some View {
        DisclosureGroup("Generation Details") {
            VStack(alignment: .leading, spacing: 20) {
                DetailSection("Models") {
                    LabeledContent("Image Captioning", value: visionModelName)
                    LabeledContent("Information Verification", value: verificationModelName)
                }

                DetailSection("Prompt") {
                    Text(prompt)
                        .textSelection(.enabled)
                }

                DetailSection("Time Elapsed", value: format(totalDuration)) {
                    ForEach(result.timings) { timing in
                        LabeledContent(stageName(timing.stage)) {
                            Text(format(timing.duration))
                                .monospacedDigit()
                        }
                    }
                }

                CaptionDetails(
                    captions: result.captions,
                    atomizedCaptions: result.atomizedCaptions
                )
                AtomicScores(
                    atomics: result.scoredAtomics,
                    retainedStatements: Set(result.retainedAtomics)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(.top)
        }
    }

    private var totalDuration: Duration {
        result.timings.reduce(.zero) { $0 + $1.duration }
    }

    private func stageName(_ stage: PipelineStage) -> LocalizedStringKey {
        switch stage {
        case .sampling: "Sampling"
        case .atomizing: "Atomizing"
        case .scoring: "Scoring"
        case .repackaging: "Repackaging"
        }
    }

    private func format(_ duration: Duration) -> String {
        duration.formatted(
            .units(
                allowed: [.minutes, .seconds],
                width: .abbreviated,
                fractionalPart: .show(length: 2)
            )
        )
    }
}

struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    let value: String?
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey,
        value: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    heading
                    Spacer()
                    detailValue
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    detailValue
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        Text(title)
            .font(.headline)
    }

    @ViewBuilder
    private var detailValue: some View {
        if let value {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
