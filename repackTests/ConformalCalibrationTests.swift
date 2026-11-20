import Foundation
import CryptoKit
import Testing
@testable import repack

@Suite("Conformal calibration")
struct ConformalCalibrationTests {
    @Test("Prompt text matches repack_renderer.py apart from indentation")
    @MainActor func promptParity() {
        // SHA-256 of Python prompt lines with indentation removed, not Swift-generated expectations.
        for (prompt, expected) in [
            (Prompts.confidenceGroupPrompt, "bd93490ec56b20f93956423abd8f70a66909588f7dfee3e18490b178d66807a6"),
            (Prompts.repackagePrompt, "1154a6e23316ad6f4a26ee9a40db425d72ed00484f3731ceb0de192162758e6e"),
            (Prompts.hedgePrompt, "e015d2ce8f9e379e80a245f57a227705f7cabfb26275d860dd3e2d1ef3934b98")
        ] {
            let normalized = prompt.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected)
        }
    }

    @Test("Exported model tables match Python thresholds and inverse lookup")
    func exportedTables() throws {
        let url = try #require(Bundle(for: CalibrationBundleMarker.self).url(forResource: ConformalCalibration.filename, withExtension: nil))
        let data = try Data(contentsOf: url)
        #expect(ConformalCalibration.hasExpectedDigest(data))
        for (model, high, medium) in [
            (DownloadableModel.e2b, 0.8408031463623047, 0.7502899169921875),
            (.e4b, 0.8255977630615234, 0.754178524017334)
        ] {
            let calibration = try ConformalCalibration(data: data, model: model)
            #expect(calibration.threshold(certainty: 90) == high)
            #expect(calibration.threshold(certainty: 80) == medium)
            #expect(calibration.threshold(certainty: 100) == 1)
            #expect(calibration.percentage(score: 1) == 100)
            #expect(calibration.percentage(score: -1) == 0)
            for (index, score) in calibration.thresholds.enumerated() {
                let firstIndex = try #require(calibration.thresholds.firstIndex(of: score))
                #expect(firstIndex <= index)
                #expect(calibration.percentage(score: score) == Int((100 * (1 - Double(firstIndex) / 1000)).rounded(.toNearestOrEven)))
            }
        }
    }

    @Test("Malformed tables and unsupported models are rejected")
    func invalidTables() throws {
        #expect(throws: (any Error).self) {
            try ConformalCalibration(data: Data("{}".utf8), model: .e2b)
        }
        let url = try #require(Bundle(for: CalibrationBundleMarker.self).url(forResource: ConformalCalibration.filename, withExtension: nil))
        let data = try Data(contentsOf: url)
        #expect(throws: CalibrationError.self) { try ConformalCalibration(data: data, model: .embeddingGemma) }
        #expect(!ConformalCalibration.hasExpectedDigest(Data("corrupt".utf8)))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["delta"] = 0.5
        let altered = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: CalibrationError.self) { try ConformalCalibration(data: altered, model: .e2b) }
    }

    @Test("Hedge marking follows Python and preserves quoted punctuation")
    @MainActor func hedgeMarking() {
        #expect(OutputRenderingsController.markHedges("It MAY appear to say 'Yes!'.") == "It [MAY] [appear to] say 'Yes!'")
        #expect(OutputRenderingsController.markHedges("Maybe it might be Mayfair.") == "Maybe it [might] be Mayfair.")
    }
}

final class CalibrationBundleMarker: NSObject {}
