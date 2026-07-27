import SwiftUI

struct RunView: View {
    private enum AccessibilityElement: Hashable {
        case result
        case failure
    }

    @Bindable var model: AppModel
    let restartAction: () -> Void
    let cancelAction: () -> Void
    let resetAction: () -> Void
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityElement?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let imageURL = model.selectedImageURL {
                    LocalImagePreview(url: imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(.rect(cornerRadius: 20))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Selected image")
                }

                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase == .processing)
        .onChange(of: model.phase) { _, phase in
            updateAccessibilityFocus(for: phase)
        }
        .toolbar {
            if model.phase == .processing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancelAction)
                        .accessibilityHint("Stops captioning and returns to your setup.")
                }
            } else if model.phase == .output {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        isResetConfirmationPresented = true
                    }
                    .accessibilityHint("Removes the current caption and image.")
                }
            }
        }
        .alert("Start Over?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Start Over", role: .destructive, action: resetAction)
        } message: {
            Text("This will remove the current image and REPACK-processed caption.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .processing:
            ProcessingView(model: model)
        case .output:
            if let result = model.result {
                ResultView(model: model, result: result, resetAction: resetAction)
                    .accessibilityFocused($accessibilityFocus, equals: .result)
            }
        case .interrupted(let message):
            InterruptedView(
                message: message,
                restartAction: restartAction,
                resetAction: resetAction
            )
            .accessibilityFocused($accessibilityFocus, equals: .failure)
        case .failed(let message):
            FailureView(
                message: message,
                canRestart: model.canCaption,
                restartAction: restartAction,
                resetAction: resetAction
            )
            .accessibilityFocused($accessibilityFocus, equals: .failure)
        default:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Preparing")
        }
    }

    private var navigationTitle: LocalizedStringKey {
        #if DEBUG
        switch model.phase {
        case .output: "DEBUG Results"
        case .interrupted: "DEBUG Interrupted"
        case .failed: "DEBUG Stopped"
        default: "DEBUG Processing"
        }
        #else
        switch model.phase {
        case .output: "Results"
        case .interrupted: "Interrupted"
        case .failed: "Stopped"
        default: "Processing"
        }
        #endif
    }

    private func updateAccessibilityFocus(for phase: AppModel.Phase) {
        switch phase {
        case .output:
            accessibilityFocus = .result
        case .interrupted, .failed:
            accessibilityFocus = .failure
        default:
            accessibilityFocus = nil
        }
    }
}
