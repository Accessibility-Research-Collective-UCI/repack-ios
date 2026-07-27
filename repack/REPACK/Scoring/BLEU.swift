import Foundation

/// Selects the effective reference length used by BLEU's brevity penalty.
nonisolated enum BLEUReferenceLengthMethod: Sendable {
    /// Uses the shortest reference for each candidate.
    case shortest

    /// Uses the closest reference length, preferring the shorter reference on ties.
    case closest
}

/// A normalized BLEU score and its corpus-level diagnostics.
///
/// `bleu`, `precisions`, `brevityPenalty`, and `lengthRatio` are expressed as
/// ratios rather than percentages.
nonisolated struct BLEUScore: Equatable, Sendable {
    let bleu: Double
    let precisions: [Double]
    let brevityPenalty: Double
    let lengthRatio: Double
    let candidateLength: Int
    let referenceLength: Int
}

/// Input errors reported while preparing or aggregating a BLEU score.
nonisolated enum BLEUScoringError: Error, Equatable, LocalizedError, Sendable {
    case emptyCorpus
    case corpusSizeMismatch(predictions: Int, referenceGroups: Int)
    case missingReferences(index: Int)
    case invalidMaxOrder(Int)
    case zeroReferenceLength

    var errorDescription: String? {
        switch self {
        case .emptyCorpus:
            "At least one candidate is required."
        case .corpusSizeMismatch(let predictions, let referenceGroups):
            "Received \(predictions) candidates but \(referenceGroups) reference groups."
        case .missingReferences(let index):
            "Candidate at index \(index) has no references."
        case .invalidMaxOrder(let order):
            "The maximum n-gram order must be greater than zero; received \(order)."
        case .zeroReferenceLength:
            "The effective reference length must be greater than zero."
        }
    }
}

/// Computes case-sensitive BLEU scores using Moses/mteval-v13a tokenization.
nonisolated enum BLEU {
    /// Scores one candidate against one or more references.
    ///
    /// Reference tokenization and n-gram counting run concurrently. BLEU-1,
    /// no smoothing, and the shortest reference-length method are the defaults.
    @concurrent
    static func compute(
        candidate: String,
        references: [String],
        maxOrder: Int = 1,
        smooth: Bool = false,
        referenceLengthMethod: BLEUReferenceLengthMethod = .shortest
    ) async throws -> BLEUScore {
        try Task.checkCancellation()
        try validate(maxOrder: maxOrder)

        guard !references.isEmpty else {
            throw BLEUScoringError.missingReferences(index: 0)
        }

        let statistics = try await segmentStatistics(
            candidate: candidate,
            references: references,
            maxOrder: maxOrder,
            referenceLengthMethod: referenceLengthMethod,
            candidateIndex: 0
        )

        return try score(from: statistics, maxOrder: maxOrder, smooth: smooth)
    }

    /// Computes one corpus-level score from aligned candidates and reference groups.
    ///
    /// Modified precision counts are aggregated before division; candidate-level
    /// scores are not averaged.
    @concurrent
    static func compute(
        predictions: [String],
        references: [[String]],
        maxOrder: Int = 1,
        smooth: Bool = false,
        referenceLengthMethod: BLEUReferenceLengthMethod = .shortest
    ) async throws -> BLEUScore {
        try Task.checkCancellation()
        try validate(maxOrder: maxOrder)

        guard !predictions.isEmpty else {
            throw BLEUScoringError.emptyCorpus
        }

        guard predictions.count == references.count else {
            throw BLEUScoringError.corpusSizeMismatch(
                predictions: predictions.count,
                referenceGroups: references.count
            )
        }

        var aggregate = SegmentStatistics.empty(maxOrder: maxOrder)

        for index in predictions.indices {
            try Task.checkCancellation()

            guard !references[index].isEmpty else {
                throw BLEUScoringError.missingReferences(index: index)
            }

            let statistics = try await segmentStatistics(
                candidate: predictions[index],
                references: references[index],
                maxOrder: maxOrder,
                referenceLengthMethod: referenceLengthMethod,
                candidateIndex: index
            )
            aggregate.add(statistics)
        }

        return try score(from: aggregate, maxOrder: maxOrder, smooth: smooth)
    }

    private static func validate(maxOrder: Int) throws {
        guard maxOrder > 0 else {
            throw BLEUScoringError.invalidMaxOrder(maxOrder)
        }
    }

    private static func segmentStatistics(
        candidate: String,
        references: [String],
        maxOrder: Int,
        referenceLengthMethod: BLEUReferenceLengthMethod,
        candidateIndex: Int
    ) async throws -> SegmentStatistics {
        let candidateTokens = try Tokenizer13a.tokenize(candidate)
        let candidateCounts = try ngramCounts(for: candidateTokens, maxOrder: maxOrder)

        var referenceLengths: [Int] = []
        referenceLengths.reserveCapacity(references.count)

        var mergedReferenceCounts: [NGram: Int] = [:]

        try await withThrowingTaskGroup(of: ReferenceStatistics.self) { group in
            for reference in references {
                group.addTask {
                    try Task.checkCancellation()
                    let tokens = try Tokenizer13a.tokenize(reference)
                    let counts = try ngramCounts(for: tokens, maxOrder: maxOrder)
                    try Task.checkCancellation()
                    return ReferenceStatistics(length: tokens.count, ngramCounts: counts)
                }
            }

            for try await statistics in group {
                referenceLengths.append(statistics.length)

                for (ngram, count) in statistics.ngramCounts {
                    mergedReferenceCounts[ngram] = max(mergedReferenceCounts[ngram, default: 0], count)
                }
            }
        }

        try Task.checkCancellation()

        let selectedReferenceLength: Int?
        switch referenceLengthMethod {
        case .shortest:
            selectedReferenceLength = referenceLengths.min()
        case .closest:
            selectedReferenceLength = referenceLengths.min {
                let leftDistance = abs($0 - candidateTokens.count)
                let rightDistance = abs($1 - candidateTokens.count)
                return (leftDistance, $0) < (rightDistance, $1)
            }
        }

        guard let effectiveReferenceLength = selectedReferenceLength else {
            throw BLEUScoringError.missingReferences(index: candidateIndex)
        }

        var possibleMatches = Array(repeating: 0, count: maxOrder)
        for order in 1...maxOrder {
            possibleMatches[order - 1] = max(candidateTokens.count - order + 1, 0)
        }

        var matches = Array(repeating: 0, count: maxOrder)
        for (ngram, candidateCount) in candidateCounts {
            matches[ngram.tokens.count - 1] += min(
                candidateCount,
                mergedReferenceCounts[ngram, default: 0]
            )
        }

        return SegmentStatistics(
            candidateLength: candidateTokens.count,
            referenceLength: effectiveReferenceLength,
            possibleMatches: possibleMatches,
            matches: matches
        )
    }

    private static func score(
        from statistics: SegmentStatistics,
        maxOrder: Int,
        smooth: Bool
    ) throws -> BLEUScore {
        guard statistics.referenceLength > 0 else {
            throw BLEUScoringError.zeroReferenceLength
        }

        let precisions = statistics.matches.indices.map { index in
            if smooth {
                return Double(statistics.matches[index] + 1)
                    / Double(statistics.possibleMatches[index] + 1)
            }

            guard statistics.possibleMatches[index] > 0 else {
                return 0
            }

            return Double(statistics.matches[index])
                / Double(statistics.possibleMatches[index])
        }

        let geometricMean: Double
        if precisions.allSatisfy({ $0 > 0 }) {
            geometricMean = exp(precisions.reduce(0) { $0 + log($1) } / Double(maxOrder))
        } else {
            geometricMean = 0
        }

        let brevityPenalty: Double
        if statistics.candidateLength == 0 {
            brevityPenalty = 0
        } else if statistics.candidateLength > statistics.referenceLength {
            brevityPenalty = 1
        } else {
            brevityPenalty = exp(
                1 - Double(statistics.referenceLength) / Double(statistics.candidateLength)
            )
        }

        let lengthRatio = Double(statistics.candidateLength) / Double(statistics.referenceLength)

        return BLEUScore(
            bleu: geometricMean * brevityPenalty,
            precisions: precisions,
            brevityPenalty: brevityPenalty,
            lengthRatio: lengthRatio,
            candidateLength: statistics.candidateLength,
            referenceLength: statistics.referenceLength
        )
    }

    private static func ngramCounts(
        for tokens: [String],
        maxOrder: Int
    ) throws -> [NGram: Int] {
        var counts: [NGram: Int] = [:]

        for order in 1...maxOrder where tokens.count >= order {
            for startIndex in 0...(tokens.count - order) {
                if startIndex.isMultiple(of: 1_024) {
                    try Task.checkCancellation()
                }

                let ngram = NGram(tokens: Array(tokens[startIndex..<(startIndex + order)]))
                counts[ngram, default: 0] += 1
            }
        }

        return counts
    }
}

private nonisolated struct NGram: Hashable, Sendable {
    let tokens: [String]
}

private nonisolated struct ReferenceStatistics: Sendable {
    let length: Int
    let ngramCounts: [NGram: Int]
}

private nonisolated struct SegmentStatistics: Sendable {
    var candidateLength: Int
    var referenceLength: Int
    var possibleMatches: [Int]
    var matches: [Int]

    static func empty(maxOrder: Int) -> SegmentStatistics {
        SegmentStatistics(
            candidateLength: 0,
            referenceLength: 0,
            possibleMatches: Array(repeating: 0, count: maxOrder),
            matches: Array(repeating: 0, count: maxOrder)
        )
    }

    mutating func add(_ other: SegmentStatistics) {
        candidateLength += other.candidateLength
        referenceLength += other.referenceLength

        for index in possibleMatches.indices {
            possibleMatches[index] += other.possibleMatches[index]
            matches[index] += other.matches[index]
        }
    }
}

/// The case-sensitive Moses/mteval-v13a tokenizer used by `BLEU`.
nonisolated enum Tokenizer13a {
    private static let alwaysSeparatedASCII: Set<UInt8> = {
        var characters = Set<UInt8>()
        characters.formUnion(32...38)
        characters.formUnion(40...43)
        characters.insert(47)
        characters.formUnion(58...64)
        characters.formUnion(91...96)
        characters.formUnion(123...126)
        return characters
    }()

    static func tokenize(_ line: String) throws -> [String] {
        let normalized = line
            .replacingOccurrences(of: "<skipped>", with: "")
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        let characters = Array(normalized)
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for (offset, index) in characters.indices.enumerated() {
            if offset.isMultiple(of: 1_024) {
                try Task.checkCancellation()
            }

            let character = characters[index]

            if character.isWhitespace {
                flushCurrent()
                continue
            }

            if let ascii = character.asciiValue, alwaysSeparatedASCII.contains(ascii) {
                flushCurrent()
                tokens.append(String(character))
                continue
            }

            if character == "." || character == "," {
                let previous = index > characters.startIndex ? characters[index - 1] : nil
                let next = index < characters.index(before: characters.endIndex)
                    ? characters[index + 1]
                    : nil
                let hasNonDigitNeighbor = previous.map { !$0.isASCIIDigit } ?? false
                    || next.map { !$0.isASCIIDigit } ?? false

                if hasNonDigitNeighbor {
                    flushCurrent()
                    tokens.append(String(character))
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "-",
               index > characters.startIndex,
               characters[index - 1].isASCIIDigit {
                flushCurrent()
                tokens.append(String(character))
                continue
            }

            current.append(character)
        }

        flushCurrent()
        return tokens
    }
}

private nonisolated extension Character {
    var isASCIIDigit: Bool {
        guard let asciiValue else { return false }
        return (48...57).contains(asciiValue)
    }
}
