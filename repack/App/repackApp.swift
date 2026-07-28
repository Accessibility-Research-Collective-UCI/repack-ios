import SwiftUI
import UIKit

final class REPACKAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CaptionExecutionCoordinator.shared.register()
        #if DEBUG
        Task { @MainActor in
            await runSamplingSettingsProbe()
        }
        #endif
        return true
    }
}

@main
struct REPACKApp: App {
    @UIApplicationDelegateAdaptor(REPACKAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
