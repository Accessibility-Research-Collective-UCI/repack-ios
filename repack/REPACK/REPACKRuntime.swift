@preconcurrency import LiteRTLM
import Foundation

@MainActor
protocol REPACKInferenceEngine: AnyObject {
    func generateCaption(image: URL, prompt: String, seed: Int) async throws -> String
    func atomize(caption: String) async throws -> REPACKAtomizationResult
    func repackage(atomics: [String]) async throws -> String
    func cancel() async
}

@MainActor
protocol REPACKEngineFactory: AnyObject {
    func validateModel(at modelURL: URL) throws
    func makeVisionEngine(modelURL: URL) async throws -> any REPACKInferenceEngine
    func makeTextEngine(modelURL: URL) async throws -> any REPACKInferenceEngine
}

@MainActor
final class LiteRTREPACKEngineFactory: REPACKEngineFactory {
    static let shared = LiteRTREPACKEngineFactory()

    private init() {}

    func validateModel(at modelURL: URL) throws {
        guard Capabilities(modelPath: modelURL.path) != nil else {
            throw REPACKError.invalidModel
        }
    }

    func makeVisionEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = false
        ExperimentalFlags.visualTokenBudget = 1_120
        let modelName = modelURL.deletingPathExtension().lastPathComponent
        REPACKMemoryDiagnostics.log("Before creating vision engine: \(modelName)")

        let configuration = try EngineConfig(
            modelPath: modelURL.path,
            backend: .gpu,
            visionBackend: .gpu,
            maxNumTokens: 4_096,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: configuration)
        try await engine.initialize()
        REPACKMemoryDiagnostics.log("After creating vision engine: \(modelName)")
        return LiteRTREPACKInferenceEngine(engine: engine)
    }

    func makeTextEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = true
        let modelName = modelURL.deletingPathExtension().lastPathComponent
        REPACKMemoryDiagnostics.log("Before creating text engine: \(modelName)")

        let configuration = try EngineConfig(
            modelPath: modelURL.path,
            backend: .gpu,
            visionBackend: nil,
            maxNumTokens: 4_096,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: configuration)
        try await engine.initialize()
        REPACKMemoryDiagnostics.log("After creating text engine: \(modelName)")
        return LiteRTREPACKInferenceEngine(engine: engine)
    }
}

@MainActor
final class LiteRTREPACKInferenceEngine: REPACKInferenceEngine {
    private let engine: Engine
    private var activeConversation: Conversation?

    init(engine: Engine) {
        self.engine = engine
    }

    func generateCaption(image: URL, prompt: String, seed: Int) async throws -> String {
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        let sampler = try SamplerConfig(
            topK: 64,
            topP: 0.95,
            temperature: 1,
            seed: seed
        )
        let conversation = try await engine.createConversation(
            with: ConversationConfig(samplerConfig: sampler)
        )
        let message = Message(
            contents: [
                .imageFile(image.path),
                .text(prompt)
            ]
        )
        return try await send(message, through: conversation).toString
    }

    func atomize(caption: String) async throws -> REPACKAtomizationResult {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCaption.isEmpty else {
            return REPACKAtomizationResult(statements: [], status: .unparseable)
        }

        let response = try await generateAtomizationList(for: trimmedCaption)
        return try await AtomizationRecovery.resolve(response) {
            // if we can't programatically repair, prompt LLM to try
            try await self.repairAtomizationList(response)
        }
    }

    private func generateAtomizationList(for caption: String) async throws -> String {
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.atomizeListPrompt, role: .system),
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        let input = """
            Caption to atomize:
            <caption>
            \(caption)
            </caption>
            """
        let response = try await send(Message(input), through: conversation).toString

        #if DEBUG
        print("[REPACK] Atomization list response: \(response)")
        #endif
        return response
    }

    private func repairAtomizationList(_ response: String) async throws -> String {
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.atomizeListRepairPrompt, role: .system),
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        let input = """
            Text to repair:
            <json>
            \(response)
            </json>
            """
        let repairedResponse = try await send(Message(input), through: conversation).toString

        #if DEBUG
        print("[REPACK] Atomization repair response: \(repairedResponse)")
        #endif
        return repairedResponse
    }

    // Retained for a manual rollback. The active atomization path intentionally does not call it.
    private func atomizeUsingToolCall(_ caption: String, isRetry: Bool) async throws -> [String] {
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.atomizePrompt, role: .system),
            tools: [SubmitAtomicStatementsTool()],
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        let sink = AtomicStatementsSink()
        let retryGuidance = isRetry
            ? """

            The previous tool call could not be parsed. Use the exact registered tool name \
            `\(SubmitAtomicStatementsTool.name)`. Do not abbreviate the name and do not write a \
            Python-style function call with parentheses. Follow the registered tool schema exactly.
            """
            : ""
        let input = """
            Caption to atomize:
            <caption>
            \(caption)
            </caption>
            \(retryGuidance)
            """

        _ = try await AtomicStatementsContext.$sink.withValue(sink) {
            try await send(Message(input), through: conversation)
        }

        let captured = await sink.take()
        guard captured.submissionCount > 0, let statements = captured.statements else {
            throw StructuredAtomizationError.noToolCall
        }
        guard captured.submissionCount == 1 else {
            throw StructuredAtomizationError.multipleToolCalls
        }

        var seen = Set<String>()
        return statements.compactMap { statement in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    func repackage(atomics: [String]) async throws -> String {
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.repackagePrompt, role: .system),
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        let data = try JSONEncoder().encode(atomics)
        guard let encodedAtomics = String(data: data, encoding: .utf8) else {
            throw StructuredAtomizationError.unableToEncodeInput
        }

        return try await send(
            Message("Atomic statements:\n\(encodedAtomics)"),
            through: conversation
        ).toString
    }

    func cancel() async {
        try? activeConversation?.cancel()
    }

    private func send(_ message: Message, through conversation: Conversation) async throws -> Message {
        activeConversation = conversation
        defer {
            if activeConversation === conversation {
                activeConversation = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await conversation.sendMessage(message)
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancel()
            }
        }
    }
}

nonisolated enum AtomizationListParser {
    static func parse(_ response: String) throws -> [String] {
        let rawResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let statements = decodeStrict(rawResponse),
           let normalized = normalize(statements) {
            return normalized
        }

        // if we can't parse JSON list fully, try to parse it string-by-string
        let candidates = jsonCandidates(from: response)
        for candidate in candidates {
            guard candidate != rawResponse else { continue }

            if let statements = decodeStrict(candidate),
               let normalized = normalize(statements) {
                return normalized
            }
        }

        for candidate in candidates {
            if let statements = decodeJSON5(candidate),
               let normalized = normalize(statements) {
                return normalized
            }
        }

        // parsing fails, attempt repair
        for candidate in candidates {
            guard let repaired = structurallyRepair(candidate) else { continue }

            if let statements = decodeStrict(repaired),
               let normalized = normalize(statements) {
                return normalized
            }
            if let statements = decodeJSON5(repaired),
               let normalized = normalize(statements) {
                return normalized
            }
        }

        throw StructuredAtomizationError.invalidListResponse
    }

    private static func decodeStrict(_ candidate: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(candidate.utf8))
    }

    private static func decodeJSON5(_ candidate: String) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(candidate.utf8),
            options: [.json5Allowed]
        ),
        JSONSerialization.isValidJSONObject(object),
        let strictData = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: strictData)
    }

    private static func normalize(_ statements: [String]) -> [String]? {
        var seen = Set<String>()
        let normalized: [String] = statements.compactMap { statement -> String? in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func jsonCandidates(from response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = [trimmed]
        let characters = Array(trimmed)
        for index in characters.indices where characters[index] == "[" {
            candidates.append(arrayCandidate(startingAt: index, in: characters))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func arrayCandidate(
        startingAt startIndex: Int,
        in characters: [Character]
    ) -> String {
        var depth = 0
        var stringDelimiter: Character?
        var isEscaped = false

        for index in startIndex..<characters.count {
            let character = characters[index]

            if let delimiter = stringDelimiter {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == delimiter {
                    stringDelimiter = nil
                }
                continue
            }

            switch character {
            case "\"", "'":
                stringDelimiter = character
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 {
                    return String(characters[startIndex...index])
                }
            default:
                break
            }
        }

        return String(characters[startIndex...])
    }

    private static func structurallyRepair(_ input: String) -> String? {
        var repaired = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var stack: [Character] = []
        var stringDelimiter: Character?
        var isEscaped = false

        for character in repaired {
            if let delimiter = stringDelimiter {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == delimiter {
                    stringDelimiter = nil
                }
                continue
            }

            switch character {
            case "\"", "'":
                stringDelimiter = character
            case "[", "{":
                stack.append(character)
            case "]":
                guard stack.last == "[" else { return nil }
                stack.removeLast()
            case "}":
                guard stack.last == "{" else { return nil }
                stack.removeLast()
            default:
                break
            }
        }

        if let stringDelimiter {
            if isEscaped {
                repaired.append("\\")
            }
            repaired.append(stringDelimiter)
        }

        for opener in stack.reversed() {
            repaired.append(opener == "[" ? "]" : "}")
        }
        return removingTrailingCommas(from: repaired)
    }

    private static func removingTrailingCommas(from input: String) -> String {
        let characters = Array(input)
        var output: [Character] = []
        var stringDelimiter: Character?
        var isEscaped = false

        for index in characters.indices {
            let character = characters[index]

            if let delimiter = stringDelimiter {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == delimiter {
                    stringDelimiter = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                stringDelimiter = character
                output.append(character)
                continue
            }

            if character == "," {
                var nextIndex = index + 1
                while nextIndex < characters.count, characters[nextIndex].isWhitespace {
                    nextIndex += 1
                }
                if nextIndex < characters.count,
                   characters[nextIndex] == "]" || characters[nextIndex] == "}" {
                    continue
                }
            }

            output.append(character)
        }

        return String(output)
    }
}

nonisolated enum AtomizationRecovery {
    @MainActor
    static func resolve(
        _ response: String,
        repair: @MainActor () async throws -> String
    ) async throws -> REPACKAtomizationResult {
        if let statements = try? AtomizationListParser.parse(response) {
            return REPACKAtomizationResult(statements: statements, status: .parsed)
        }

        // Greedy MTP generation is deterministic, so repeating the original prompt with the same
        // model state is unlikely to improve malformed JSON. Give the model one syntax-only repair.
        do {
            let repairedResponse = try await repair()
            let statements = try AtomizationListParser.parse(repairedResponse)
            return REPACKAtomizationResult(statements: statements, status: .parsed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Cancellation is user intent and must escape. Other repair failures affect only this
            // caption, so an explicit empty result lets verification continue with a visible warning.
            try Task.checkCancellation()
            REPACKMemoryDiagnostics.log("Atomization JSON repair failed")
            return REPACKAtomizationResult(statements: [], status: .unparseable)
        }
    }
}

// Retained with the inactive tool-calling implementation for manual rollback.
nonisolated enum AtomizationRetryPolicy {
    static let maximumAttempts = 5

    @MainActor
    static func run<T>(
        operation: (_ attempt: Int) async throws -> T,
        onRetry: (_ attempt: Int, _ error: any Error) -> Void = { _, _ in }
    ) async throws -> T {
        for attempt in 0..<maximumAttempts {
            do {
                return try await operation(attempt)
            } catch {
                try Task.checkCancellation()
                guard attempt + 1 < maximumAttempts, shouldRetry(error) else {
                    throw error
                }
                onRetry(attempt + 1, error)
            }
        }

        preconditionFailure("Atomization retry loop must return or throw.")
    }

    static func shouldRetry(_ error: any Error) -> Bool {
        if let structuredError = error as? StructuredAtomizationError {
            return structuredError == .invalidListResponse
                || structuredError == .noToolCall
                || structuredError == .multipleToolCalls
        }

        guard let liteRTError = error as? LiteRTLMError,
              case .conversation(let conversationError) = liteRTError else {
            return false
        }

        switch conversationError {
        case .invalidResponse(let details):
            return details.localizedCaseInsensitiveContains("sendMessage returned null")
                || details.localizedCaseInsensitiveContains("tool call")
                || details.localizedCaseInsensitiveContains("parse")
        case .invalidJson(let details):
            return details.localizedCaseInsensitiveContains("tool call")
                || details.localizedCaseInsensitiveContains("parse")
        case .toolExecutionError:
            return true
        default:
            return false
        }
    }
}

nonisolated enum StructuredAtomizationError: Error, Equatable, LocalizedError, Sendable {
    case invalidListResponse
    case noToolCall
    case multipleToolCalls
    case missingCaptureContext
    case unableToEncodeInput

    var errorDescription: String? {
        switch self {
        case .invalidListResponse:
            String(localized: "The model did not submit structured atomic statements.")
        case .noToolCall:
            String(localized: "The model did not submit structured atomic statements.")
        case .multipleToolCalls:
            String(localized: "The model submitted atomic statements more than once.")
        case .missingCaptureContext:
            String(localized: "The structured atomization result could not be captured.")
        case .unableToEncodeInput:
            String(localized: "The atomic statements could not be prepared for repackaging.")
        }
    }
}

nonisolated struct CapturedAtomicStatements: Sendable {
    let statements: [String]?
    let submissionCount: Int
}

actor AtomicStatementsSink {
    private var statements: [String]?
    private var submissionCount = 0

    func submit(_ statements: [String]) {
        submissionCount += 1
        if self.statements == nil {
            self.statements = statements
        }
    }

    func take() -> CapturedAtomicStatements {
        defer {
            statements = nil
            submissionCount = 0
        }
        return CapturedAtomicStatements(
            statements: statements,
            submissionCount: submissionCount
        )
    }
}

nonisolated enum AtomicStatementsContext {
    @TaskLocal static var sink: AtomicStatementsSink?
}

struct SubmitAtomicStatementsTool: Tool {
    static let name = "submit_atomic_statements"
    static let description = """
        Submit the final atomic statements. Call this tool exactly once and do not answer in prose.
        """

    @ToolParam(
        description: "The complete list of atomic factual statements extracted from the caption."
    )
    var statements: [String]

    init() {}

    func run() async throws -> Any {
        guard let sink = AtomicStatementsContext.sink else {
            throw StructuredAtomizationError.missingCaptureContext
        }
        await sink.submit(statements)
        return ["accepted": true]
    }
}
