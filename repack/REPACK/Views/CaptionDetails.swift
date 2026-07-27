import SwiftUI

struct CaptionDetails: View {
    let captions: [CaptionSample]
    let atomizedCaptions: [AtomizedCaption]

    var body: some View {
        DetailSection("Original Caption") {
            if let caption = captions.first {
                captionText(caption)
            }
        }

        DetailSection("Sample Captions") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(captions.dropFirst()) { caption in
                    DisclosureGroup {
                        atomicStatements(for: caption)
                            .padding(.vertical, 4)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                sampleLabel(caption)
                                captionText(caption)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                sampleLabel(caption)
                                captionText(caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }

    private func sampleLabel(_ caption: CaptionSample) -> some View {
        Text("Sample \(caption.index)")
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func atomicStatements(for caption: CaptionSample) -> some View {
        let statements = atomizedCaption(for: caption)?.statements ?? []
        if statements.isEmpty {
            Text("No atomic statements available.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(statements, id: \.self) { statement in
                    Text(statement)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func captionText(_ caption: CaptionSample) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if atomizedCaption(for: caption)?.status == .unparseable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(warning(for: caption))
            }

            Text(caption.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func atomizedCaption(for caption: CaptionSample) -> AtomizedCaption? {
        atomizedCaptions.first { $0.caption.id == caption.id }
    }

    private func warning(for caption: CaptionSample) -> String {
        switch caption.kind {
        case .reference:
            String(localized: "Atomic statements could not be parsed for the original caption.")
        case .sample:
            String(localized: "Atomic statements could not be parsed for Sample \(caption.index).")
        }
    }
}
