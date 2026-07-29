#if BENCHMARKING
import SwiftUI

struct BenchmarkRunningView: View {
    let model: BenchmarkViewModel
    @State private var isConfirmingStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                runStatus
                overallProgress
                timingSummary

                Button(role: .destructive) {
                    isConfirmingStop = true
                } label: {
                    Text("Stop Benchmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint(
                    "Asks for confirmation before stopping the benchmark."
                )
            }
            .padding()
        }
        .keepsBenchmarkScreenAwake()
        .alert("Stop Benchmark?", isPresented: $isConfirmingStop) {
            Button("Keep Running", role: .cancel) {}
            Button("Stop Benchmark", role: .destructive) {
                model.cancel()
            }
        } message: {
            Text(
                "Completed image results will be retained, but the benchmark cannot be resumed."
            )
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        if model.phase == .cooldown {
            Text("Cooling down")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Next image starts in \(model.cooldownRemaining) seconds.")
                .foregroundStyle(.secondary)
            ProgressView()
                .accessibilityLabel("Thermal cooldown")
                .accessibilityValue(
                    "\(model.cooldownRemaining) seconds remaining"
                )
        } else {
            Text("Benchmarking \(model.currentFile ?? "")")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            stageProgress
        }
    }

    private var overallProgress: some View {
        ProgressView(
            value: Double(model.completedImageCount),
            total: Double(model.totalImageCount)
        ) {
            Text("Images")
        } currentValueLabel: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    imageCountText
                    Spacer()
                    estimatedTimeText
                }

                VStack(alignment: .leading, spacing: 4) {
                    imageCountText
                    estimatedTimeText
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Overall benchmark progress")
        .accessibilityValue(overallProgressAccessibilityValue)
    }

    private var overallProgressAccessibilityValue: String {
        let progress = "\(model.completedImageCount) of \(model.totalImageCount) images complete"
        guard let estimate = model.estimatedTimeRemaining else {
            return progress
        }
        return progress
            + ". About "
            + estimate.formatted(
                .units(
                    allowed: [.hours, .minutes, .seconds],
                    width: .wide
                )
            )
            + " remaining"
    }

    private var imageCountText: some View {
        Text("\(model.completedImageCount) of \(model.totalImageCount)")
    }

    @ViewBuilder
    private var estimatedTimeText: some View {
        if let estimate = model.estimatedTimeRemaining {
            Text(
                "About \(estimate.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))) remaining"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var stageProgress: some View {
        VStack(spacing: 12) {
            ForEach(model.algorithmStages) { stage in
                let status = stageStatus(stage)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        stageLabel(stage, status: status)
                        Spacer()
                        if status == .active {
                            activeStageProgress
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        stageLabel(stage, status: status)
                        if status == .active {
                            activeStageProgress
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stage.title)
                .accessibilityValue(status.accessibilityValue)
            }
        }
    }

    private func stageLabel(
        _ stage: BenchmarkStage,
        status: StageStatus
    ) -> some View {
        Label {
            HStack {
                Text(stage.title)
                Text(status.title)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: status.systemImage)
        }
    }

    @ViewBuilder
    private var activeStageProgress: some View {
        if let fraction = model.currentProgress?.fractionCompleted {
            ProgressView(value: fraction)
                .frame(minWidth: 110)
        } else {
            ProgressView()
        }
    }

    private var timingSummary: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(
                    "Active elapsed",
                    value: model.elapsed(at: context.date).formatted(
                        .units(
                            allowed: [.minutes, .seconds],
                            width: .abbreviated
                        )
                    )
                )
                if let average = model.averageDuration {
                    LabeledContent(
                        "Average per image",
                        value: average.formatted(
                            .units(
                                allowed: [.minutes, .seconds],
                                width: .abbreviated
                            )
                        )
                    )
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func stageStatus(_ stage: BenchmarkStage) -> StageStatus {
        guard let currentStage = model.currentProgress?.stage,
              let currentIndex = model.algorithmStages.firstIndex(of: currentStage),
              let stageIndex = model.algorithmStages.firstIndex(of: stage) else {
            return .waiting
        }
        if stageIndex < currentIndex {
            return .complete
        }
        return stageIndex == currentIndex ? .active : .waiting
    }
}

private enum StageStatus: Equatable {
    case waiting
    case active
    case complete

    var systemImage: String {
        switch self {
        case .waiting: "circle"
        case .active: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        }
    }

    var accessibilityValue: String {
        title
    }

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .active: "In progress"
        case .complete: "Complete"
        }
    }
}
#endif
