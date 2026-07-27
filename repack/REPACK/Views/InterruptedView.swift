import SwiftUI

struct InterruptedView: View {
    let message: String
    let restartAction: () -> Void
    let resetAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ContentUnavailableView(
                "Captioning Interrupted",
                systemImage: "arrow.counterclockwise.circle.fill",
                description: Text(message)
            )

            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack { actions }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Restart Captioning", action: restartAction)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

        Button("Start Over", action: resetAction)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }
}
