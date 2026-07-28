import Accelerate

/// A row-major cosine-similarity matrix for normalized reference and sample vectors.
nonisolated struct SemanticSimilarityMatrix {
    let sampleRanges: [Range<Int>]

    private let referenceCount: Int
    private let values: [Float]

    init(
        reference: [[Float]],
        samples: [[[Float]]]
    ) throws {
        guard let dimension = reference.first?.count, dimension > 0 else {
            throw SemanticScoringError.invalidEmbeddingDimension
        }

        let generated = samples.flatMap { $0 }
        guard reference.allSatisfy({ $0.count == dimension }),
              generated.allSatisfy({ $0.count == dimension }) else {
            throw SemanticScoringError.invalidEmbeddingDimension
        }

        referenceCount = reference.count
        sampleRanges = samples.reduce(into: []) { ranges, vectors in
            let start = ranges.last?.upperBound ?? 0
            ranges.append(start..<(start + vectors.count))
        }
        values = Self.multiply(
            generated: generated.flatMap { $0 },
            generatedCount: generated.count,
            reference: reference.flatMap { $0 },
            referenceCount: reference.count,
            dimension: dimension
        )
    }

    subscript(generatedIndex: Int, referenceIndex: Int) -> Float {
        values[generatedIndex * referenceCount + referenceIndex]
    }

    private static func multiply(
        generated: [Float],
        generatedCount: Int,
        reference: [Float],
        referenceCount: Int,
        dimension: Int
    ) -> [Float] {
        guard generatedCount > 0, referenceCount > 0 else { return [] }

        var result = [Float](
            repeating: 0,
            count: generatedCount * referenceCount
        )
        var transposedReference = [Float](
            repeating: 0,
            count: reference.count
        )
        generated.withUnsafeBufferPointer { generatedBuffer in
            reference.withUnsafeBufferPointer { referenceBuffer in
                transposedReference.withUnsafeMutableBufferPointer { transposedBuffer in
                    vDSP_mtrans(
                        referenceBuffer.baseAddress!,
                        1,
                        transposedBuffer.baseAddress!,
                        1,
                        vDSP_Length(dimension),
                        vDSP_Length(referenceCount)
                    )
                    result.withUnsafeMutableBufferPointer { resultBuffer in
                        vDSP_mmul(
                            generatedBuffer.baseAddress!,
                            1,
                            transposedBuffer.baseAddress!,
                            1,
                            resultBuffer.baseAddress!,
                            1,
                            vDSP_Length(generatedCount),
                            vDSP_Length(referenceCount),
                            vDSP_Length(dimension)
                        )
                    }
                }
            }
        }
        return result
    }
}
