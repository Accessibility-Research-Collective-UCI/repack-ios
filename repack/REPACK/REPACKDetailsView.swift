import SwiftUI

struct REPACKDetailsView: View {
    let result: REPACKResult
    let visionModelName: String
    let verificationModelName: String
    let prompt: String

    @ScaledMetric(relativeTo: .caption) private var sampleColumnWidth = 64

    var body: some View {
        DisclosureGroup("Generation Details") {
            VStack(alignment: .leading, spacing: 20) {
                detailSection("Models") {
                    LabeledContent("Image Captioning", value: visionModelName)
                    LabeledContent("Information Verification", value: verificationModelName)
                }

                detailSection("Prompt") {
                    Text(prompt)
                        .textSelection(.enabled)
                }

                detailSection("Time Elapsed", value: format(totalDuration)) {
                    ForEach(result.timings) { timing in
                        LabeledContent(stageName(timing.stage)) {
                            Text(format(timing.duration))
                                .monospacedDigit()
                        }
                    }
                }

                detailSection("Original Caption") {
                    Text(result.captions.first?.text ?? "")
                        .textSelection(.enabled)
                }

                detailSection("Sample Captions") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Sample")
                                .frame(width: sampleColumnWidth, alignment: .leading)
                            Text("Caption")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                        ForEach(result.captions.dropFirst()) { caption in
                            HStack(alignment: .top, spacing: 12) {
                                Text(caption.index, format: .number)
                                    .monospacedDigit()
                                    .frame(width: sampleColumnWidth, alignment: .leading)
                                    .accessibilityLabel("Sample \(caption.index)")

                                Text(caption.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                detailSection("Atomic Statements and Scores") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(result.scoredAtomics) { atomic in
                            let isRetained = retainedStatements.contains(atomic.statement)

                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(atomic.matches) { match in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Sample \(match.sampleIndex)")
                                                .font(.caption.bold())
                                            Text(
                                                match.statement
                                                    ?? String(localized: "No atomic statement")
                                            )
                                            .multilineTextAlignment(.leading)
                                            Text(
                                                match.score,
                                                format: .percent.precision(.fractionLength(1))
                                            )
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(
                                        systemName: isRetained
                                            ? "checkmark.circle.fill"
                                            : "xmark.circle.fill"
                                    )
                                    .imageScale(.medium)
                                    .frame(width: 20, alignment: .leading)
                                    .foregroundStyle(isRetained ? .green : .secondary)
                                    .accessibilityLabel(isRetained ? "Retained" : "Not retained")

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(atomic.statement)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .multilineTextAlignment(.leading)
                                        HStack(spacing: 3) {
                                            Text("BLEU average:")
                                            Text(
                                                atomic.averageScore,
                                                format: .percent.precision(.fractionLength(1))
                                            )
                                        }
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top)
        }
    }

    private func detailSection<Content: View>(
        _ title: LocalizedStringKey,
        value: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let value {
                    Text(value)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalDuration: Duration {
        result.timings.reduce(.zero) { total, timing in
            total + timing.duration
        }
    }

    private var retainedStatements: Set<String> {
        Set(result.retainedAtomics)
    }

    private func stageName(_ stage: REPACKStage) -> LocalizedStringKey {
        switch stage {
        case .sampling:
            "Sampling"
        case .atomizing:
            "Atomizing"
        case .scoring:
            "Scoring"
        case .repackaging:
            "Repackaging"
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
