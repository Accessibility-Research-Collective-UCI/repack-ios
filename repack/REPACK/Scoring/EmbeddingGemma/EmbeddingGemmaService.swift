import Foundation
import SentencepieceTokenizer

/// Serializes access to the stateful LiteRT embedding interpreter.
actor EmbeddingGemmaService: TextEmbeddingProviding {
    static let sequenceLength = 256
    static let embeddingDimension = 768
    static let prompt = "task: sentence similarity | query: "

    private let resources: EmbeddingModelResources
    private let threadCount: Int
    private let clock = ContinuousClock()

    private var interpreter: LiteRTEmbeddingInterpreter?
    private var tokenizer: SentencepieceTokenizer?

    init(resources: EmbeddingModelResources, threadCount: Int = 4) {
        self.resources = resources
        self.threadCount = threadCount
    }

    func embeddings(for statements: [String]) async throws -> [[Float]] {
        try Task.checkCancellation()
        let requiresPreparation = interpreter == nil
        let preparationStart = clock.now
        try prepareIfNeeded()
        if requiresPreparation {
            debugLog(
                "Prepared EmbeddingGemma in "
                    + "\(preparationStart.duration(to: clock.now)) "
                    + "with \(threadCount) CPU threads."
            )
        }

        let batchStart = clock.now
        var result: [[Float]] = []
        result.reserveCapacity(statements.count)
        for (index, statement) in statements.enumerated() {
            try Task.checkCancellation()
            let embeddingStart = clock.now
            result.append(try embedding(for: statement))
            debugLog(
                "Computed EmbeddingGemma embedding \(index + 1)/\(statements.count) "
                    + "in \(embeddingStart.duration(to: clock.now))."
            )
        }
        debugLog(
            "Computed \(result.count) EmbeddingGemma embeddings in "
                + "\(batchStart.duration(to: clock.now))."
        )
        return result
    }

    private func prepareIfNeeded() throws {
        guard interpreter == nil else { return }

        let delegationStart = clock.now
        let interpreter = try LiteRTEmbeddingInterpreter(
            modelURL: resources.modelURL,
            threadCount: threadCount,
            sequenceLength: Self.sequenceLength,
            embeddingDimension: Self.embeddingDimension
        )
        debugLog(
            "Created and allocated the EmbeddingGemma interpreter with an "
                + "explicit \(threadCount)-thread XNNPACK delegate in "
                + "\(delegationStart.duration(to: clock.now))."
        )

        let tokenizer = try SentencepieceTokenizer(
            modelPath: resources.tokenizerURL.path(percentEncoded: false),
            tokenOffset: 0
        )
        guard tokenizer.padTokenId == 0,
              tokenizer.eosTokenId == 1,
              tokenizer.bosTokenId == 2 else {
            throw SemanticScoringError.invalidModelSignature(
                "tokenizer special token IDs do not match EmbeddingGemma"
            )
        }

        self.interpreter = interpreter
        self.tokenizer = tokenizer
    }

    private func embedding(for statement: String) throws -> [Float] {
        guard let handle = interpreter,
              let tokenizer else {
            throw SemanticScoringError.invalidModelSignature(
                "interpreter was not fully prepared"
            )
        }
        let encoded = try tokenizer.encode(Self.prompt + statement)
        let contentLimit = Self.sequenceLength - 2
        var inputIDs = [Int32]()
        inputIDs.reserveCapacity(Self.sequenceLength)
        inputIDs.append(Int32(tokenizer.bosTokenId))
        inputIDs.append(contentsOf: encoded.prefix(contentLimit).map(Int32.init))
        inputIDs.append(Int32(tokenizer.eosTokenId))

        let paddingCount = Self.sequenceLength - inputIDs.count
        inputIDs.append(
            contentsOf: repeatElement(
                Int32(tokenizer.padTokenId),
                count: paddingCount
            )
        )

        return try normalized(handle.invoke(inputIDs))
    }

    private func normalized(_ values: [Float]) throws -> [Float] {
        let squaredSum = values.reduce(Float.zero) { partial, value in
            partial + value * value
        }
        let magnitude = sqrt(squaredSum)
        guard magnitude.isFinite, magnitude > 0 else {
            throw SemanticScoringError.invalidEmbedding
        }
        return values.map { $0 / magnitude }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[REPACK] \(message())")
        #endif
    }
}
