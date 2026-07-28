import SwiftUI

struct SimilarityThresholdControl: View {
    let metric: ScoringMetric
    let value: Double
    let onChange: (Double) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    label
                    Spacer()
                    formattedValue
                }
                VStack(alignment: .leading, spacing: 4) {
                    label
                    formattedValue
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            controls

            Text(
                "A higher threshold only retains details that are more consistently supported across caption samples."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var configuration: ThresholdConfiguration {
        metric.threshold
    }

    private var binding: Binding<Double> {
        Binding(
            get: { value },
            set: { onChange(configuration.normalized($0)) }
        )
    }

    private var label: some View {
        Text("Verification threshold")
            .font(.headline)
    }

    private var formattedValue: some View {
        Text(value, format: .number.precision(.fractionLength(2)))
            .monospacedDigit()
    }

    private var accessibilityValue: Text {
        Text(value, format: .number.precision(.fractionLength(2)))
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                slider
                HStack {
                    adjustmentButton(direction: .decrease)
                    Spacer()
                    adjustmentButton(direction: .increase)
                }
            }
        } else {
            HStack(spacing: 12) {
                adjustmentButton(direction: .decrease)
                slider
                adjustmentButton(direction: .increase)
            }
        }
    }

    private var slider: some View {
        Slider(value: binding, in: configuration.range) {
            Text("Verification threshold")
        } minimumValueLabel: {
            endpoint(configuration.range.lowerBound)
        } maximumValueLabel: {
            endpoint(configuration.range.upperBound)
        } ticks: {
            SliderTickContentForEach(configuration.ticks, id: \.self) {
                SliderTick($0)
            }
        }
        .accessibilityLabel("Verification threshold")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            "Adjusts how consistently a detail must appear."
        )
    }

    private func endpoint(_ value: Double) -> some View {
        Text(value, format: .number.precision(.fractionLength(1)))
            .fixedSize()
    }

    private func adjustmentButton(
        direction: ThresholdAdjustmentDirection
    ) -> some View {
        let adjustment = direction.multiplier * configuration.adjustment
        let adjusted = configuration.normalized(value + adjustment)
        return Button {
            onChange(adjusted)
        } label: {
            Image(systemName: direction.systemImage)
                .font(.system(size: 17))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(direction.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            "Changes the threshold by \(configuration.adjustment, format: .number.precision(.fractionLength(2)))."
        )
        .disabled(
            direction == .decrease
                ? value <= configuration.range.lowerBound
                : value >= configuration.range.upperBound
        )
    }
}

private enum ThresholdAdjustmentDirection {
    case decrease
    case increase

    var multiplier: Double {
        self == .decrease ? -1 : 1
    }

    var systemImage: String {
        self == .decrease ? "minus" : "plus"
    }

    var accessibilityLabel: LocalizedStringKey {
        self == .decrease
            ? "Decrease threshold"
            : "Increase threshold"
    }
}
