import CryptoKit
import Foundation
import Testing
@testable import repack

@Suite("BERTScore Python Reference", .serialized)
nonisolated struct BERTScoreReferenceTests {
    // Required integration test: missing model assets must fail, not silently skip validation.
    @Test("Swift tokenization, IDF weights, and F1 match Python for both calibrations")
    func pythonReference() async throws {
        let resources = try #require(EmbeddingModelResources.bundled(),
                                     "Install the documented DevelopmentAssets/Models files before this test")
        let url = try #require(Bundle(for: FixtureBundle.self).url(
            forResource: "bertscore-reference", withExtension: "json"))
        let fixture = try JSONDecoder().decode(ReferenceFixture.self, from: Data(contentsOf: url))
        #expect(fixture.layer == 16)
        #expect(try checksum(resources.modelURL) == fixture.model_sha256)
        #expect(try checksum(resources.tokenizerURL) == fixture.tokenizer_sha256)
        for expected in fixture.calibrations {
            let calibration = try #require(IDFCalibration(rawValue: expected.name))
            #expect(calibration.filename == expected.filename)
            #expect(try checksum(resources.calibrationURL(for: calibration)) == expected.sha256)
            let service = EmbeddingGemmaService(resources: resources, calibration: calibration)
            let embeddings = try await service.embeddings(for: fixture.texts)
            #expect(expected.scores.count == fixture.pairs.count)
            #expect(expected.weights.count == embeddings.count)
            for index in embeddings.indices {
                #expect(embeddings[index].tokenIDs == fixture.token_ids[index])
                #expect(embeddings[index].weights.count == expected.weights[index].count)
                for (actual, reference) in zip(embeddings[index].weights, expected.weights[index]) {
                    #expect(abs(Double(actual) - reference) < 1e-5)
                }
            }
            for (pair, score) in zip(fixture.pairs, expected.scores) {
                let actual = try BERTScore.f1(embeddings[pair[0]], embeddings[pair[1]])
                #expect(abs(Double(actual) - score) <= fixture.tolerance,
                        "Python parity failed for \(expected.name): \(fixture.texts[pair[0]]) / \(fixture.texts[pair[1]])")
            }
            await service.clearStatementCache()
        }
    }

    private func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class FixtureBundle: NSObject {}

nonisolated private struct ReferenceFixture: Decodable {
    let model_sha256: String
    let tokenizer_sha256: String
    let layer: Int
    let tolerance: Double
    let texts: [String]
    let token_ids: [[Int]]
    let pairs: [[Int]]
    let calibrations: [Calibration]

    struct Calibration: Decodable {
        let name: String
        let filename: String
        let sha256: String
        let weights: [[Double]]
        let scores: [Double]
    }
}
