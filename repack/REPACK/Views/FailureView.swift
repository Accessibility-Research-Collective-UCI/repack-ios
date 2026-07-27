import SwiftUI

struct FailureView: View {
    let message: String
    let canRestart: Bool
    let restartAction: () -> Void
    let resetAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "REPACK Stopped",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )

            if canRestart {
                Button("Restart Captioning", action: restartAction)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }

            if canRestart {
                Button("Start Over", action: resetAction)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Start Over", action: resetAction)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
