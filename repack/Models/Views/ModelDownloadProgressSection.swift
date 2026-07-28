import SwiftUI

/// Presents active model-transfer progress and cancellation.
struct ModelDownloadProgressSection: View {
    let isWaiting: Bool
    let progress: DownloadProgress?
    let cancelAction: () async -> Void

    @State private var isCancelConfirmationPresented = false

    var body: some View {
        Section("Download Progress") {
            Text("Keep this page open while the models are downloading.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isWaiting {
                ProgressView {
                    Text("Waiting for download to start")
                }
                .accessibilityLabel("Model download")
                .accessibilityValue("Waiting to start")
            } else if let progress {
                VStack(alignment: .leading) {
                    Text(progress.currentFileDescription)
                        .font(.subheadline)
                    ProgressView(value: progress.fractionCompleted)
                    Text(
                        progress.fractionCompleted,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Model download")
                .accessibilityValue(progress.accessibilityValue)
            }

            Button(
                "Cancel Download",
                systemImage: "xmark.circle",
                role: .destructive
            ) {
                isCancelConfirmationPresented = true
            }
            .accessibilityHint(
                "Stops the download and removes temporary files."
            )
        }
        .alert(
            "Cancel Download?",
            isPresented: $isCancelConfirmationPresented
        ) {
            Button("Keep Downloading", role: .cancel) {}
            Button("Cancel Download", role: .destructive) {
                Task {
                    await cancelAction()
                }
            }
        } message: {
            Text(
                "The current download will stop and temporary files will be removed."
            )
        }
    }
}
