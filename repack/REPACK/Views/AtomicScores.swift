import SwiftUI

struct AtomicScores: View {
    let atomics: [ScoredAtomic]
    let retainedStatements: Set<String>
    let scoringMetric: ScoringMetric

    var body: some View {
        DetailSection("Atomic Statements and Scores") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(atomics) { atomic in
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    Text(
                                        match.score,
                                        format: .number.precision(.fractionLength(2))
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        scoreLabel(atomic)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scoreLabel(_ atomic: ScoredAtomic) -> some View {
        let isRetained = retainedStatements.contains(atomic.statement)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isRetained ? "checkmark.circle.fill" : "xmark.circle.fill")
                .frame(width: 20, alignment: .leading)
                .foregroundStyle(isRetained ? .green : .secondary)
                .accessibilityLabel(isRetained ? "Retained" : "Not retained")

            VStack(alignment: .leading, spacing: 4) {
                Text(atomic.statement)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Text(
                    "\(scoringMetric.scoreLabel): \(atomic.averageScore, format: .number.precision(.fractionLength(2)))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
