import SwiftUI

/// Presents one downloadable catalog item with its installation state.
struct DownloadableModelRow: View {
    let model: DownloadableModel
    let isDownloaded: Bool
    let isSupported: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.displayName)
                    Text(model.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isSupported {
                        Text("Unavailable on this iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(
                    systemName: isDownloaded
                        ? "checkmark.circle.fill"
                        : "arrow.down.circle"
                )
                .foregroundStyle(
                    isDownloaded ? Color.green : Color.accentColor
                )
                .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(model.displayName)
        .accessibilityValue(isDownloaded ? "Downloaded" : "")
        .accessibilityHint(
            isDownloaded
                ? "This model is already on this device."
                : model.shortDescription
        )
        .disabled(isDisabled || !isSupported)
    }
}
