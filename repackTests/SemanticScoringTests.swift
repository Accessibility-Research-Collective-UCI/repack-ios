import Foundation
import Testing
@testable import repack

@Suite("Semantic Scoring")
@MainActor
struct SemanticScoringTests {
    @Test("Bundled EmbeddingGemma model produces normalized embeddings")
    func bundledModelSmokeTest() async throws {
        let resources = try #require(
            EmbeddingModelResources.bundled(in: .main)
        )
        let service = EmbeddingGemmaService(resources: resources)

        let vectors = try await service.embeddings(
            for: ["A red package.", "A white logo."]
        )

        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy {
            $0.count == EmbeddingGemmaService.embeddingDimension
        })
        for vector in vectors {
            let squaredMagnitude = vector.reduce(0) {
                $0 + Double($1 * $1)
            }
            #expect(abs(squaredMagnitude - 1) < 0.000_1)
        }
    }

    @Test("Semantic scoring finds the best statement within each sample")
    func bestMatchesAndAverages() async throws {
        let scorer: any CaptionScorer = SemanticCaptionScorer()
        let reference = PreparedCaptionScoringInput(
            captionID: 0,
            statements: ["red package", "white logo"],
            vectors: [
                [1, 0],
                [0, 1]
            ]
        )
        let diagonal = Float(1 / Double(2).squareRoot())
        let samples = [
            PreparedCaptionScoringInput(
                captionID: 1,
                statements: ["red box", "bright mark"],
                vectors: [
                    [1, 0],
                    [0, 1]
                ]
            ),
            PreparedCaptionScoringInput(
                captionID: 2,
                statements: ["colored object"],
                vectors: [[diagonal, diagonal]]
            )
        ]

        let results = try await scorer.score(
            reference: reference,
            samples: samples,
            progress: { _, _ in }
        )

        #expect(results.count == 2)
        #expect(results[0].matches.map(\.statement) == ["red box", "colored object"])
        #expect(results[1].matches.map(\.statement) == ["bright mark", "colored object"])
        #expect(abs(results[0].averageScore - 0.853_553_4) < 0.000_001)
        #expect(abs(results[1].averageScore - 0.853_553_4) < 0.000_001)
    }

    @Test("Semantic scoring transposes non-square embedding matrices correctly")
    func nonSquareEmbeddingMatrix() async throws {
        let scorer: any CaptionScorer = SemanticCaptionScorer()
        let reference = PreparedCaptionScoringInput(
            captionID: 0,
            statements: ["x axis", "y axis"],
            vectors: [
                [1, 0, 0],
                [0, 1, 0]
            ]
        )
        let diagonal = Float(1 / Double(2).squareRoot())
        let sample = PreparedCaptionScoringInput(
            captionID: 1,
            statements: ["x match", "y match", "diagonal"],
            vectors: [
                [1, 0, 0],
                [0, 1, 0],
                [diagonal, diagonal, 0]
            ]
        )

        let results = try await scorer.score(
            reference: reference,
            samples: [sample],
            progress: { _, _ in }
        )

        #expect(results.map(\.matches[0].statement) == ["x match", "y match"])
        #expect(results.map(\.matches[0].score) == [1, 1])
    }

    @Test("Negative similarity and empty samples score zero")
    func clampingAndEmptySamples() async throws {
        let scorer: any CaptionScorer = SemanticCaptionScorer()
        let reference = PreparedCaptionScoringInput(
            captionID: 0,
            statements: ["reference"],
            vectors: [[1, 0]]
        )
        let samples = [
            PreparedCaptionScoringInput(
                captionID: 1,
                statements: ["opposite"],
                vectors: [[-1, 0]]
            ),
            PreparedCaptionScoringInput(
                captionID: 2,
                statements: [],
                vectors: []
            )
        ]

        let result = try #require(
            try await scorer.score(
                reference: reference,
                samples: samples,
                progress: { _, _ in }
            ).first
        )

        #expect(result.matches.map(\.score) == [0, 0])
        #expect(result.matches[0].statement == "opposite")
        #expect(result.matches[1].statement == nil)
        #expect(result.averageScore == 0)
    }
}
