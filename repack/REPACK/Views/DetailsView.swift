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
                    if let caption = result.captions.first {
                        captionText(caption)
                    }
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
                            DisclosureGroup {
                                sampleAtomicStatements(for: caption)
                                    .padding(.leading, sampleColumnWidth + 12)
                                    .padding(.vertical, 4)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(caption.index, format: .number)
                                        .monospacedDigit()
                                        .frame(width: sampleColumnWidth, alignment: .leading)
                                        .accessibilityLabel("Sample \(caption.index)")

                                    captionText(caption)
                                }
                                .accessibilityElement(children: .combine)
                            }
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

    @ViewBuilder
    private func sampleAtomicStatements(for caption: REPACKCaption) -> some View {
        let statements = atomizedCaption(for: caption)?.statements ?? []

        if statements.isEmpty {
            Text("No atomic statements available.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(statements, id: \.self) { statement in
                    Text(statement)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func captionText(_ caption: REPACKCaption) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if atomizationStatus(for: caption) == .unparseable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(atomizationWarning(for: caption))
            }

            Text(caption.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func atomizationStatus(for caption: REPACKCaption) -> REPACKAtomizationStatus {
        atomizedCaption(for: caption)?.status ?? .parsed
    }

    private func atomizedCaption(for caption: REPACKCaption) -> REPACKAtomizedCaption? {
        result.atomizedCaptions.first(where: { $0.caption.id == caption.id })
    }

    private func atomizationWarning(for caption: REPACKCaption) -> String {
        switch caption.kind {
        case .reference:
            String(localized: "Atomic statements could not be parsed for the original caption.")
        case .sample:
            String(localized: "Atomic statements could not be parsed for Sample \(caption.index).")
        }
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
