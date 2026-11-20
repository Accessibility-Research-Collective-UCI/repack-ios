import Foundation
import SentencepieceTokenizer

/// Owns the interpreter, calibration, and run-scoped statement cache on one actor.
actor EmbeddingGemmaService: TextEmbeddingProviding {
    static let sequenceLength = 256
    static let embeddingDimension = 768
    static let calibrationSequenceLength = 2048

    private let resources: EmbeddingModelResources
    private let calibration: IDFCalibration?
    private let threadCount: Int
    private var interpreter: LiteRTEmbeddingInterpreter?
    private var tokenizer: SentencepieceTokenizer?
    private var idf: IDFWeights?
    private var statementCache: [String: TokenEmbedding] = [:]

    init(resources: EmbeddingModelResources, calibration: IDFCalibration?, threadCount: Int = 4) {
        self.resources = resources
        self.calibration = calibration
        self.threadCount = threadCount
    }

    func clearStatementCache() { statementCache.removeAll() }

    func embeddings(for statements: [String]) async throws -> MeasuredEmbeddings {
        let clock = ContinuousClock()
        let start = clock.now
        try Task.checkCancellation()
        try prepareIfNeeded()
        var result: [TokenEmbedding] = []
        for statement in statements {
            try Task.checkCancellation()
            if let cached = statementCache[statement] {
                result.append(cached)
            } else {
                let embedding = try embedding(for: statement)
                statementCache[statement] = embedding
                result.append(embedding)
            }
        }
        return MeasuredEmbeddings(embeddings: result, duration: start.duration(to: clock.now))
    }

    private func prepareIfNeeded() throws {
        guard interpreter == nil else { return }
        guard let calibration else { throw SemanticScoringError.unsupportedCalibration }
        let tokenizer = try SentencepieceTokenizer(
            modelPath: resources.tokenizerURL.path(percentEncoded: false), tokenOffset: 0
        )
        guard tokenizer.padTokenId == 0, tokenizer.eosTokenId == 1,
              tokenizer.bosTokenId == 2 else {
            throw SemanticScoringError.invalidModelSignature("Unexpected special token IDs")
        }
        let statements = try calibration.statements(
            from: Data(contentsOf: resources.calibrationURL(for: calibration))
        )
        var weights = IDFWeights()
        for statement in statements {
            try Task.checkCancellation()
            // Match the Python tokenizer limit, independently of the mobile inference window.
            let content = try tokenizer.encode(statement.trimmingCharacters(in: .whitespacesAndNewlines))
            weights.addDocument([2] + content.prefix(Self.calibrationSequenceLength - 2) + [1])
        }
        let interpreter = try LiteRTEmbeddingInterpreter(
            modelURL: resources.modelURL, threadCount: threadCount,
            sequenceLength: Self.sequenceLength, embeddingDimension: Self.embeddingDimension
        )
        self.tokenizer = tokenizer
        self.idf = weights
        self.interpreter = interpreter
    }

    private func embedding(for statement: String) throws -> TokenEmbedding {
        guard let interpreter, let tokenizer, let idf else {
            throw SemanticScoringError.invalidModelSignature("Interpreter was not prepared")
        }
        let content = try tokenizer.encode(statement.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = [2] + content.prefix(Self.sequenceLength - 2) + [1]
        let padding = Self.sequenceLength - tokens.count
        let inputIDs = tokens.map(Int32.init) + Array(repeating: Int32(0), count: padding)
        var values = Array(try interpreter.invoke(inputIDs).prefix(tokens.count * Self.embeddingDimension))
        for index in tokens.indices {
            try Task.checkCancellation()
            let range = (index * Self.embeddingDimension)..<((index + 1) * Self.embeddingDimension)
            let magnitude = sqrt(values[range].reduce(Float.zero) { $0 + $1 * $1 })
            guard magnitude.isFinite, magnitude > 0 else { throw SemanticScoringError.invalidEmbedding }
            for offset in range { values[offset] /= magnitude }
        }
        return try TokenEmbedding(tokenIDs: tokens, vectors: values,
                                  dimension: Self.embeddingDimension,
                                  weights: tokens.map { idf[$0] })
    }
}
