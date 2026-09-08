import Darwin
import Foundation

nonisolated enum E4BMode: Equatable, Sendable {
    case unavailable
    case adaptive
    case resident
}

nonisolated struct DevicePolicy: Equatable, Sendable {
    // E4B-ready to pipeline peak has measured about 2.6 GB. Keep roughly 1 GB in reserve.
    static let minimumAvailableForResidentEngines = UInt64(3_500) * 1_024 * 1_024

    let modelIdentifier: String

    var e4BMode: E4BMode {
        switch modelIdentifier {
        // iPhone 15 and 15 Plus (6 GB Physical RAM)
        case "iPhone15,4", "iPhone15,5":
            .unavailable
        // iPhone 15 Pro/Pro Max, all iPhone 16 models, and iPhone 17/17e (8 GB);
        // iPhone 17 Pro/Pro Max and Air (12 GB). Keep both engines resident.
        case "iPhone16,1", "iPhone16,2",
             "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4", "iPhone17,5",
             "iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4", "iPhone18,5":
            .resident
        default:
            .adaptive
        }
    }

    var allowsE4B: Bool {
        e4BMode != .unavailable
    }

    static var current: Self {
        #if targetEnvironment(simulator)
        if let simulatedIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return Self(modelIdentifier: simulatedIdentifier)
        }
        #endif
        return Self(modelIdentifier: hardwareModelIdentifier())
    }

    private static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }

        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

nonisolated protocol MemoryProviding: Sendable {
    func availableMemory() -> UInt64
}

nonisolated struct SystemMemoryProvider: MemoryProviding {
    func availableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}
