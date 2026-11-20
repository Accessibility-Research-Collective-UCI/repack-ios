import Foundation
import Testing
@testable import repack

@Suite("Semantic Scoring")
@MainActor
struct SemanticScoringTests {
    @Test("IDF counts documents, preserves duplicate documents, and weights unseen tokens")
    func idfDocuments() {
        var idf = IDFWeights()
        idf.addDocument([2, 10, 10, 1])
        idf.addDocument([2, 10, 10, 1])
        idf.addDocument([2, 20, 1])
        #expect(idf.documentCount == 3)
        #expect(idf[2] == 0)
        #expect(idf[1] == 0)
        #expect(abs(idf[10] - Float(log(4.0 / 3))) < 1e-6)
        #expect(abs(idf[20] - Float(log(2.0))) < 1e-6)
        #expect(abs(idf[99] - Float(log(4.0))) < 1e-6)
    }

    @Test("Calibration validates the pair and preserves repeated statements")
    func calibrationCorpus() throws {
        let data = Data(#"{"vlm":"gemma-4-e4b","llm":"gemma-4-e2b","sources":[{"statements":["a","a"]},{"statements":["b"]}]}"#.utf8)
        #expect(try IDFCalibration.e4b.statements(from: data) == ["a", "a", "b"])
        #expect(throws: SemanticScoringError.unsupportedCalibration) {
            try IDFCalibration.e2b.statements(from: data)
        }
        #expect(throws: (any Error).self) {
            try IDFCalibration.e4b.statements(from: Data("{}".utf8))
        }
        let empty = Data(#"{"vlm":"gemma-4-e2b","llm":"gemma-4-e2b","sources":[]}"#.utf8)
        #expect(throws: SemanticScoringError.emptyCalibration) {
            try IDFCalibration.e2b.statements(from: empty)
        }
    }

    @Test("Calibration follows the vision and text model pair")
    func calibrationSelection() throws {
        let e2b = URL(filePath: "/models/gemma-4-E2B-it.litertlm")
        let e4b = URL(filePath: "/models/gemma-4-E4B-it.litertlm")
        #expect(try IDFCalibration.resolve(visionModel: e2b, textModel: e2b) == .e2b)
        #expect(try IDFCalibration.resolve(visionModel: e4b, textModel: e2b) == .e4b)
        #expect(throws: SemanticScoringError.unsupportedCalibration) {
            try IDFCalibration.resolve(visionModel: e4b, textModel: e4b)
        }
    }

    @Test("Weighted token matching uses both directions and non-square matrices")
    func weightedF1() throws {
        let reference = try embedding([[1, 0], [0, 1]], weights: [1, 3])
        let sample = try embedding([[1, 0]])
        // Precision = 1/4, recall = 1, F1 = 0.4. Sentence pooling gives another score.
        #expect(abs(try BERTScore.f1(reference, sample) - 0.4) < 1e-6)
        #expect(abs(try BERTScore.f1(sample, reference) - 0.4) < 1e-6)
        #expect(abs(try BERTScore.f1(reference, reference) - 1) < 1e-6)
    }

    @Test("Zero-weight special tokens remain possible matching targets")
    func specialTokenMatching() throws {
        let reference = try embedding([[1, 0]], weights: [1])
        let sample = try embedding([[1, 0], [0.6, 0.8]], weights: [0, 1])
        #expect(abs(try BERTScore.f1(reference, sample) - 0.75) < 1e-6)
        let zero = try embedding([[1, 0]], weights: [0])
        #expect(try BERTScore.f1(zero, reference) == 0)
    }

    @Test("Duplicate atomics preserve occurrences, sample membership, ties, and averages")
    func duplicateMatches() async throws {
        let x = try embedding([[1, 0]])
        let y = try embedding([[0, 1]])
        let reference = PreparedCaptionScoringInput(captionID: 0,
            statements: ["reference", "reference"], embeddings: [x, x])
        let samples = [
            PreparedCaptionScoringInput(captionID: 1,
                statements: ["first", "tie", "first"], embeddings: [x, x, x]),
            PreparedCaptionScoringInput(captionID: 2, statements: ["other"], embeddings: [y]),
            PreparedCaptionScoringInput(captionID: 3, statements: [], embeddings: [])
        ]
        let results = try await SemanticCaptionScorer().score(reference: reference, samples: samples,
                                                             progress: { _, _ in })
        #expect(results.count == 2)
        #expect(results.map(\.index) == [0, 1])
        for result in results {
            #expect(result.matches.map(\.statement) == ["first", "other", nil])
            #expect(result.matches.map(\.score) == [1, 0, 0])
            #expect(abs(result.averageScore - 1.0 / 3) < 1e-6)
        }
    }

    @Test("Invalid embedding data and mismatched statement counts fail")
    func invalidInput() async throws {
        #expect(throws: SemanticScoringError.invalidEmbedding) {
            try embedding([[Float.nan, 0]])
        }
        #expect(throws: SemanticScoringError.invalidEmbeddingDimension) {
            try TokenEmbedding(tokenIDs: [1], vectors: [1], dimension: 2, weights: [1])
        }
        #expect(throws: SemanticScoringError.invalidEmbeddingDimension) {
            try BERTScore.f1(embedding([[1, 0]]), embedding([[1, 0, 0]]))
        }
        await #expect(throws: SemanticScoringError.statementVectorCountMismatch) {
            try await SemanticCaptionScorer().score(
                reference: PreparedCaptionScoringInput(captionID: 0, statements: ["a"], embeddings: []),
                samples: [], progress: { _, _ in })
        }
    }

    @Test("Cancellation stops token matching")
    func cancellation() async throws {
        let value = try embedding([[1, 0]])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BERTScore.f1(value, value)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Bundled token model produces normalized token vectors",
          .enabled(if: EmbeddingModelResources.bundled() != nil))
    func bundledModelSmokeTest() async throws {
        let resources = try #require(EmbeddingModelResources.bundled())
        let service = EmbeddingGemmaService(resources: resources, calibration: .e2b)
        let measured = try await service.embeddings(for: ["A red package.", "A red package."])
        #expect(measured.duration > .zero)
        let values = measured.embeddings
        #expect(values.count == 2)
        #expect(values[0] == values[1])
        #expect(values[0].tokenIDs == [2, 236776, 2604, 8289, 236761, 1])
        for value in values {
            for token in value.tokenIDs.indices {
                let start = token * value.dimension
                let magnitude = value.vectors[start..<(start + value.dimension)].reduce(0) { $0 + $1 * $1 }
                #expect(abs(magnitude - 1) < 1e-4)
            }
        }
        let cached = try await service.embeddings(for: ["A red package."])
        #expect(cached.embeddings == [values[0]])
        #expect(cached.duration > .zero)
        await service.clearStatementCache()
    }

    private func embedding(_ vectors: [[Float]], weights: [Float]? = nil) throws -> TokenEmbedding {
        try TokenEmbedding(tokenIDs: Array(vectors.indices), vectors: vectors.flatMap { $0 },
                           dimension: vectors.first?.count ?? 2,
                           weights: weights ?? Array(repeating: 1, count: vectors.count))
    }
}
