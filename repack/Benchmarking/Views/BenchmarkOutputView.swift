#if BENCHMARKING
import SwiftUI
import UIKit

struct BenchmarkOutputView: View {
    let model: BenchmarkViewModel
    @State private var isConfirmingNewBenchmark = false
    @State private var copyConfirmationCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                if let output = model.output {
                    if let failure = output.failure {
                        Label(
                            failure.message,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }

                    TimingSummaryView(results: output.results)

                    Button {
                        UIPasteboard.general.string = output.formattedJSON()
                        copyConfirmationCount += 1
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: String(localized: "JSON copied to the clipboard")
                        )
                    } label: {
                        Label("Copy JSON", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 16)
                    .accessibilityHint(
                        "Copies the complete benchmark result as JSON to the clipboard."
                    )

                    if copyConfirmationCount > 0 {
                        Label("JSON copied to the clipboard", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }

                    ShareLink(
                        item: BenchmarkExportItem(output: output),
                        preview: SharePreview(
                            output.exportFilename,
                            image: Image(systemName: "doc.text")
                        )
                    ) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityHint(
                        "Opens the share sheet to AirDrop or export the benchmark JSON file."
                    )
                }

                Button {
                    isConfirmingNewBenchmark = true
                } label: {
                    Text("New Benchmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 24)
                .accessibilityHint(
                    "Asks for confirmation before discarding the displayed benchmark result."
                )
            }
            .padding()
        }
        .sensoryFeedback(.success, trigger: copyConfirmationCount)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Start a New Benchmark?", isPresented: $isConfirmingNewBenchmark) {
            Button("Keep Results", role: .cancel) {}
            Button("New Benchmark", role: .destructive) {
                model.reset()
            }
        } message: {
            Text(
                "These results will no longer be accessible unless you copy or export the JSON first."
            )
        }
    }

    private var title: String {
        switch model.output?.status {
        case .completed: "Benchmark Complete"
        case .interrupted: "Benchmark Interrupted"
        case .failed: "Benchmark Failed"
        case nil: "Benchmark Ended"
        }
    }
}

private struct TimingSummaryView: View {
    let results: BenchmarkResults

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Total", value: results.totalTime)
            row("Average", value: results.averageTime)
            row("Shortest", value: results.shortestTime)
            row("Longest", value: results.longestTime)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Timing summary")
        .accessibilityValue(accessibilitySummary)
    }

    private func row(_ title: LocalizedStringKey, value: Double) -> some View {
        LabeledContent {
            Text("\(value, format: .number.precision(.fractionLength(2))) seconds")
        } label: {
            Text(title)
        }
    }

    private var accessibilitySummary: String {
        "Total \(formatted(results.totalTime)) seconds. "
            + "Average \(formatted(results.averageTime)) seconds. "
            + "Shortest \(formatted(results.shortestTime)) seconds. "
            + "Longest \(formatted(results.longestTime)) seconds."
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}
#endif
