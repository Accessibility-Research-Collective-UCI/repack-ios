import Foundation

nonisolated enum IDFCalibration: String, CaseIterable, Sendable {
    case e2b = "gemma-4-e2b"
    case e4b = "gemma-4-e4b"

    var filename: String { "vlm-\(rawValue)_llm-gemma-4-e2b.json" }

    static func resolve(visionModel: URL, textModel: URL) throws -> Self {
        guard DownloadableModel(modelURL: textModel) == .e2b else {
            throw SemanticScoringError.unsupportedCalibration
        }
        switch DownloadableModel(modelURL: visionModel) {
        case .e2b: return .e2b
        case .e4b: return .e4b
        default: throw SemanticScoringError.unsupportedCalibration
        }
    }

    func statements(from data: Data) throws -> [String] {
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.vlm == rawValue, corpus.llm == "gemma-4-e2b" else {
            throw SemanticScoringError.unsupportedCalibration
        }
        let statements = corpus.sources.flatMap(\.statements)
        guard !statements.isEmpty else { throw SemanticScoringError.emptyCalibration }
        return statements
    }

    private struct Corpus: Decodable {
        let vlm: String
        let llm: String
        let sources: [Source]
        struct Source: Decodable { let statements: [String] }
    }
}

nonisolated struct IDFWeights: Sendable {
    private(set) var documentCount = 0
    private var frequencies: [Int: Int] = [:]

    mutating func addDocument(_ tokens: [Int]) {
        documentCount += 1
        for token in Set(tokens) { frequencies[token, default: 0] += 1 }
    }

    subscript(token: Int) -> Float {
        Float(log(Double(documentCount + 1) / Double(frequencies[token, default: 0] + 1)))
    }
}
