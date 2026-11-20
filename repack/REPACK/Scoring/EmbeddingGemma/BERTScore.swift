import Accelerate

/// Greedy token matching with IDF-weighted precision and recall, without baseline rescaling.
nonisolated enum BERTScore {
    static func f1(_ reference: TokenEmbedding, _ sample: TokenEmbedding) throws -> Float {
        try Task.checkCancellation()
        guard reference.dimension == sample.dimension else {
            throw SemanticScoringError.invalidEmbeddingDimension
        }
        let referenceTotal = reference.weights.reduce(0, +)
        let sampleTotal = sample.weights.reduce(0, +)
        guard referenceTotal > 0, sampleTotal > 0 else { return 0 }
        let rows = reference.tokenIDs.count
        let columns = sample.tokenIDs.count
        let dimension = reference.dimension
        var transposed = [Float](repeating: 0, count: sample.vectors.count)
        var similarities = [Float](repeating: 0, count: rows * columns)
        // Nonempty buffers follow from the positive weight sums and validated shapes.
        sample.vectors.withUnsafeBufferPointer { input in
            transposed.withUnsafeMutableBufferPointer { output in
                vDSP_mtrans(input.baseAddress!, 1, output.baseAddress!, 1,
                            vDSP_Length(dimension), vDSP_Length(columns))
            }
        }
        reference.vectors.withUnsafeBufferPointer { left in
            transposed.withUnsafeBufferPointer { right in
                similarities.withUnsafeMutableBufferPointer { output in
                    vDSP_mmul(left.baseAddress!, 1, right.baseAddress!, 1,
                              output.baseAddress!, 1, vDSP_Length(rows),
                              vDSP_Length(columns), vDSP_Length(dimension))
                }
            }
        }
        var referenceMax = [Float](repeating: -.infinity, count: rows)
        var sampleMax = [Float](repeating: -.infinity, count: columns)
        for row in 0..<rows {
            try Task.checkCancellation()
            for column in 0..<columns {
                let value = similarities[row * columns + column]
                referenceMax[row] = max(referenceMax[row], value)
                sampleMax[column] = max(sampleMax[column], value)
            }
        }
        let precision = zip(referenceMax, reference.weights).reduce(Float.zero) {
            $0 + $1.0 * ($1.1 / referenceTotal)
        }
        let recall = zip(sampleMax, sample.weights).reduce(Float.zero) {
            $0 + $1.0 * ($1.1 / sampleTotal)
        }
        let denominator = precision + recall
        guard denominator != 0 else { return 0 }
        let score = 2 * precision * recall / denominator
        guard score.isFinite else { throw SemanticScoringError.invalidEmbedding }
        return score
    }
}
