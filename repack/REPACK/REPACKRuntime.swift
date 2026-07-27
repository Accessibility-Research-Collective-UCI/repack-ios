@preconcurrency import LiteRTLM
import Foundation

@MainActor
protocol REPACKInferenceEngine: AnyObject {
    func generateCaption(image: URL, prompt: String, seed: Int) async throws -> String
    func atomize(caption: String) async throws -> [String]
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

    func atomize(caption: String) async throws -> [String] {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCaption.isEmpty else { return [] }

        return try await AtomizationRetryPolicy.run { attempt in
            try await self.atomizeUsingList(trimmedCaption, isRetry: attempt > 0)
        } onRetry: { attempt, error in
            #if DEBUG
            print(
                "[REPACK] Retrying atomization after list parsing failure "
                    + "(attempt \(attempt + 1)/\(AtomizationRetryPolicy.maximumAttempts)): "
                    + error.localizedDescription
            )
            #endif
            REPACKMemoryDiagnostics.log("Atomization list parsing retry")
        }
    }

    private func atomizeUsingList(_ caption: String, isRetry: Bool) async throws -> [String] {
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.atomizeListPrompt, role: .system),
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        let retryGuidance = isRetry
            ? """

            Your previous response could not be parsed. Return only a valid JSON array of strings. \
            Do not use Markdown fences, an object wrapper, or any explanatory text.
            """
            : ""
        let input = """
            Caption to atomize:
            <caption>
            \(caption)
            </caption>
            \(retryGuidance)
            """
        let response = try await send(Message(input), through: conversation).toString

        #if DEBUG
        print("[REPACK] Atomization list response: \(response)")
        #endif
        return try AtomizationListParser.parse(response)
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
        let candidate = jsonCandidate(from: response)

        let statements: [String]
        do {
            statements = try JSONDecoder().decode([String].self, from: Data(candidate.utf8))
        } catch {
            throw StructuredAtomizationError.invalidListResponse
        }

        var seen = Set<String>()
        let normalized: [String] = statements.compactMap { statement -> String? in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        guard !normalized.isEmpty else {
            throw StructuredAtomizationError.invalidListResponse
        }
        return normalized
    }

    private static func jsonCandidate(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"),
              trimmed.hasSuffix("```"),
              let firstLineEnd = trimmed.firstIndex(of: "\n") else {
            return trimmed
        }

        let contentStart = trimmed.index(after: firstLineEnd)
        let contentEnd = trimmed.index(trimmed.endIndex, offsetBy: -3)
        return String(trimmed[contentStart..<contentEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
