#if BENCHMARKING
import Foundation
import UIKit

@MainActor
protocol BenchmarkImageProviding {
    var expectedImageCount: Int { get }
    func images() throws -> [URL]
}

@MainActor
struct BundleBenchmarkImageProvider: BenchmarkImageProviding {
    let bundle: Bundle
    let expectedImageCount: Int

    init(bundle: Bundle = .main, expectedImageCount: Int = 25) {
        self.bundle = bundle
        self.expectedImageCount = expectedImageCount
    }

    func images() throws -> [URL] {
        let images = bundle.urls(
            forResourcesWithExtension: "jpg",
            subdirectory: "Benchmarking"
        ) ?? []
        guard images.count == expectedImageCount else {
            throw BenchmarkFailure(
                kind: .setupFailure,
                message: String(
                    localized:
                        "Expected \(expectedImageCount) benchmark images, but found \(images.count)."
                ),
                file: nil
            )
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@MainActor
protocol BenchmarkSleeping {
    func sleep(for duration: Duration) async throws
}

@MainActor
struct BenchmarkTaskSleeper: BenchmarkSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
protocol BenchmarkDateProviding {
    var now: Date { get }
}

@MainActor
struct SystemBenchmarkDateProvider: BenchmarkDateProviding {
    var now: Date { Date() }
}

nonisolated struct BenchmarkDeviceInformation: Equatable, Sendable {
    let hardwareModel: String
    let identifier: String?
    let appVersion: String
    let buildVersion: String
    let osVersion: String
}

@MainActor
protocol BenchmarkDeviceInformationProviding {
    func information() -> BenchmarkDeviceInformation
}

@MainActor
struct SystemBenchmarkDeviceInformationProvider: BenchmarkDeviceInformationProviding {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func information() -> BenchmarkDeviceInformation {
        BenchmarkDeviceInformation(
            hardwareModel: Self.hardwareModel(),
            identifier: UIDevice.current.identifierForVendor?.uuidString,
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            buildVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            osVersion: UIDevice.current.systemVersion
        )
    }

    private static func hardwareModel() -> String {
        var value = utsname()
        guard uname(&value) == 0 else { return "unknown" }
        return withUnsafePointer(to: &value.machine) {
            String(
                cString: $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: 1
                ) { $0 }
            )
        }
    }
}

#endif
