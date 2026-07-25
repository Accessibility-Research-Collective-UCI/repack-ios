import Foundation
import Testing
@testable import repack

@Suite("BLEU")
nonisolated struct BLEUTests {
    private struct Fixture: Sendable {
        let name: String
        let candidate: String
        let references: [String]
        let expectedScores: [Double]
    }

    private let fixtures: [Fixture] = [
        Fixture(
            name: "Exact match",
            candidate: "the cat sat on the mat",
            references: ["the cat sat on the mat"],
            expectedScores: [1, 1, 1, 1]
        ),
        Fixture(
            name: "One substitution",
            candidate: "the cat sat on the rug",
            references: ["the cat sat on the mat"],
            expectedScores: [0.833333, 0.816497, 0.793701, 0.759836]
        ),
        Fixture(
            name: "Same words reordered",
            candidate: "the mat sat on the cat",
            references: ["the cat sat on the mat"],
            expectedScores: [1, 0.894427, 0.584804, 0]
        ),
        Fixture(
            name: "Short correct prefix",
            candidate: "the cat sat on",
            references: ["the cat sat on the mat"],
            expectedScores: [0.606531, 0.606531, 0.606531, 0.606531]
        ),
        Fixture(
            name: "Extra words",
            candidate: "the small cat sat on the mat today",
            references: ["the cat sat on the mat"],
            expectedScores: [0.75, 0.654654, 0.598408, 0.541082]
        ),
        Fixture(
            name: "No overlap",
            candidate: "birds fly above blue oceans",
            references: ["the cat sat on the mat"],
            expectedScores: [0, 0, 0, 0]
        ),
        Fixture(
            name: "Repeated token",
            candidate: "the the the the the the",
            references: ["the cat sat on the mat"],
            expectedScores: [0.333333, 0, 0, 0]
        ),
        Fixture(
            name: "Synonyms only",
            candidate: "a feline rested upon a rug",
            references: ["the cat sat on the mat"],
            expectedScores: [0, 0, 0, 0]
        ),
        Fixture(
            name: "Partial phrase match",
            candidate: "the cat slept on the mat",
            references: ["the cat sat on the mat"],
            expectedScores: [0.833333, 0.707107, 0.5, 0]
        ),
        Fixture(
            name: "Mixed reference wording",
            candidate: "the feline sat on the mat",
            references: [
                "the cat sat on the mat",
                "the feline sat upon the mat"
            ],
            expectedScores: [1, 1, 0.908560, 0.707107]
        ),
        Fixture(
            name: "Exact second reference",
            candidate: "a cat is sitting on the mat",
            references: [
                "the cat sat on the mat",
                "a cat is sitting on the mat"
            ],
            expectedScores: [1, 1, 1, 1]
        ),
        Fixture(
            name: "Words from both references",
            candidate: "the feline sat on the mat",
            references: [
                "the cat sat on the mat",
                "a feline rested upon the rug"
            ],
            expectedScores: [1, 0.774597, 0.669433, 0.562341]
        ),
        Fixture(
            name: "Closest reference length",
            candidate: "the cat sat",
            references: [
                "the cat sat on the mat",
                "the cat sat"
            ],
            expectedScores: [1, 1, 1, 0]
        ),
        Fixture(
            name: "Clipping across references",
            candidate: "the the the cat cat cat",
            references: [
                "the cat sat on the mat",
                "the cat lay by the cat"
            ],
            expectedScores: [0.666667, 0.365148, 0, 0]
        ),
        Fixture(
            name: "Partial match across references",
            candidate: "the fast brown fox jumps",
            references: [
                "the quick brown fox jumps",
                "a fast brown fox leaps"
            ],
            expectedScores: [1, 0.866025, 0.793701, 0]
        ),
        Fixture(
            name: "Exact alternate syntax",
            candidate: "the label is predicted by the model",
            references: [
                "the model predicts the label",
                "the label is predicted by the model"
            ],
            expectedScores: [1, 1, 1, 1]
        )
    ]

    @Test("Provided BLEU-1 through BLEU-4 score matrix")
    func providedScoreMatrix() async throws {
        for fixture in fixtures {
            for maxOrder in 1...4 {
                let result = try await BLEU.compute(
                    candidate: fixture.candidate,
                    references: fixture.references,
                    maxOrder: maxOrder
                )
                let expected = fixture.expectedScores[maxOrder - 1]

                #expect(
                    abs(result.bleu - expected) <= 0.000001,
                    "\(fixture.name), BLEU-\(maxOrder)"
                )
            }
        }
    }

    @Test("BLEU-1 is the default")
    func defaultIsBLEUOne() async throws {
        let fixture = fixtures[1]
        let defaultResult = try await BLEU.compute(
            candidate: fixture.candidate,
            references: fixture.references
        )
        let explicitResult = try await BLEU.compute(
            candidate: fixture.candidate,
            references: fixture.references,
            maxOrder: 1
        )

        #expect(defaultResult == explicitResult)
        #expect(defaultResult.precisions.count == 1)
        #expect(abs(defaultResult.bleu - 0.833333) <= 0.000001)
    }

    @Test("Score diagnostics")
    func diagnostics() async throws {
        let result = try await BLEU.compute(
            candidate: "the cat sat on the rug",
            references: ["the cat sat on the mat"],
            maxOrder: 4
        )

        #expect(abs(result.precisions[0] - 5.0 / 6.0) <= 1e-12)
        #expect(abs(result.precisions[1] - 4.0 / 5.0) <= 1e-12)
        #expect(abs(result.precisions[2] - 3.0 / 4.0) <= 1e-12)
        #expect(abs(result.precisions[3] - 2.0 / 3.0) <= 1e-12)
        #expect(result.brevityPenalty == 1)
        #expect(result.lengthRatio == 1)
        #expect(result.candidateLength == 6)
        #expect(result.referenceLength == 6)
    }

    @Test("Reference-length modes can produce different penalties")
    func referenceLengthMethodsCanProduceDifferentPenalties() async throws {
        let candidate = "a b c d e f"
        let references = [
            "a b c d",
            "a b c d e f g"
        ]

        let shortest = try await BLEU.compute(
            candidate: candidate,
            references: references,
            referenceLengthMethod: .shortest
        )
        let closest = try await BLEU.compute(
            candidate: candidate,
            references: references,
            referenceLengthMethod: .closest
        )

        #expect(shortest.referenceLength == 4)
        #expect(shortest.brevityPenalty == 1)
        #expect(shortest.bleu == 1)

        let expectedPenalty = exp(1 - 7.0 / 6.0)
        #expect(closest.referenceLength == 7)
        #expect(abs(closest.brevityPenalty - expectedPenalty) <= 1e-12)
        #expect(abs(closest.bleu - closest.brevityPenalty) <= 1e-12)
    }

    @Test("Closest reference-length ties prefer the shorter reference")
    func closestReferenceLengthUsesShorterReferenceOnTie() async throws {
        let result = try await BLEU.compute(
            candidate: "a b c d",
            references: [
                "a b c",
                "a b c d e"
            ],
            referenceLengthMethod: .closest
        )

        #expect(result.referenceLength == 3)
        #expect(result.brevityPenalty == 1)
    }

    @Test("Reference order does not affect parallel aggregation")
    func referenceOrderAndLargeDynamicReferenceList() async throws {
        let candidate = "the cat sat on the mat"
        var references = (0..<256).map { "unrelated reference number \($0)" }
        references.append(candidate)

        let forward = try await BLEU.compute(
            candidate: candidate,
            references: references,
            maxOrder: 4,
            referenceLengthMethod: .closest
        )
        let reversed = try await BLEU.compute(
            candidate: candidate,
            references: references.reversed(),
            maxOrder: 4,
            referenceLengthMethod: .closest
        )

        #expect(forward == reversed)
        #expect(forward.bleu == 1)
    }

    @Test("Corpus scoring uses micro aggregation")
    func corpusUsesMicroAggregation() async throws {
        let result = try await BLEU.compute(
            predictions: [
                "a b c d",
                "a"
            ],
            references: [
                ["a b c x"],
                ["z"]
            ]
        )

        #expect(abs(result.bleu - 0.6) <= 1e-12)
        #expect(result.precisions == [0.6])
        #expect(result.candidateLength == 5)
        #expect(result.referenceLength == 5)
    }

    @Test("An empty candidate has a zero score")
    func emptyCandidate() async throws {
        let result = try await BLEU.compute(candidate: "", references: ["reference"])

        #expect(result.bleu == 0)
        #expect(result.precisions == [0])
        #expect(result.brevityPenalty == 0)
        #expect(result.lengthRatio == 0)
        #expect(result.candidateLength == 0)
        #expect(result.referenceLength == 1)
    }

    @Test("Add-one smoothing handles missing higher orders")
    func addOneSmoothingForMissingHigherOrders() async throws {
        let result = try await BLEU.compute(
            candidate: "a",
            references: ["a"],
            maxOrder: 4,
            smooth: true
        )

        #expect(result.bleu == 1)
        #expect(result.precisions == [1, 1, 1, 1])
    }

    @Test("13a tokenizer produces exact ordered tokens")
    func tokenizer13aNormalization() throws {
        let cases: [(input: String, expected: [String])] = [
            (
                "Hello, World!",
                ["Hello", ",", "World", "!"]
            ),
            (
                "5-6 costs $1,000.50",
                ["5", "-", "6", "costs", "$", "1,000.50"]
            ),
            (
                "Hello, &quot;World!&quot; &amp; &lt;x&gt;<skipped>",
                ["Hello", ",", "\"", "World", "!", "\"", "&", "<", "x", ">"]
            ),
            (
                "inter-\nnational\ntext",
                ["international", "text"]
            ),
            (
                "café 猫",
                ["café", "猫"]
            ),
            (
                ".5 5. 3.14 1,000.50",
                [".5", "5", ".", "3.14", "1,000.50"]
            ),
            (
                "Cat cat",
                ["Cat", "cat"]
            )
        ]

        for testCase in cases {
            #expect(
                try Tokenizer13a.tokenize(testCase.input) == testCase.expected,
                "Unexpected tokens for \(testCase.input)"
            )
        }
    }

    @Test("Invalid inputs report typed errors")
    func validationErrors() async {
        await expectBLEUError(.missingReferences(index: 0)) {
            _ = try await BLEU.compute(candidate: "candidate", references: [])
        }

        await expectBLEUError(.emptyCorpus) {
            _ = try await BLEU.compute(predictions: [], references: [])
        }

        await expectBLEUError(.corpusSizeMismatch(predictions: 1, referenceGroups: 0)) {
            _ = try await BLEU.compute(predictions: ["candidate"], references: [])
        }

        await expectBLEUError(.missingReferences(index: 1)) {
            _ = try await BLEU.compute(
                predictions: ["first", "second"],
                references: [["reference"], []]
            )
        }

        await expectBLEUError(.invalidMaxOrder(0)) {
            _ = try await BLEU.compute(
                candidate: "candidate",
                references: ["reference"],
                maxOrder: 0
            )
        }

        await expectBLEUError(.zeroReferenceLength) {
            _ = try await BLEU.compute(candidate: "candidate", references: [""])
        }
    }

    @Test("Pre-cancelled scoring propagates cancellation")
    func preCancelledComputationThrowsCancellationError() async {
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await BLEU.compute(candidate: "candidate", references: ["candidate"])
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    private func expectBLEUError(
        _ expected: BLEUScoringError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as BLEUScoringError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), received \(error)")
        }
    }
}
