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
        ExperimentalFlags.enableSpeculativeDecoding = false
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

        return try await AtomizationRetryPolicy.run { _ in
            try await self.atomizeUsingResponseFormat(trimmedCaption)
        } onRetry: { attempt, error in
            #if DEBUG
            print(
                "[REPACK] Retrying response-format atomization "
                    + "(attempt \(attempt + 1)/\(AtomizationRetryPolicy.maximumAttempts)): "
                    + String(reflecting: error)
            )
            #endif
            REPACKMemoryDiagnostics.log("Response-format atomization retry")
        }
    }

    private func atomizeUsingResponseFormat(_ caption: String) async throws -> [String] {
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.structuredAtomizePrompt, role: .system),
            samplerConfig: sampler,
            automaticToolCalling: false,
            enableResponseFormat: true
        )
        let conversation = try await engine.createConversation(with: configuration)
        let input = """
            Caption to atomize:
            <caption>
            \(caption)
            </caption>
            """
        let response = try await send(
            Message(input),
            through: conversation,
            responseFormat: AtomizationResponseFormat.make()
        )
        #if DEBUG
        print("[REPACK] Atomization response: \(response.toString)")
        #endif

        let structuredResponse = try JSONDecoder().decode(
            StructuredAtomizationResponse.self,
            from: Data(response.toString.utf8)
        )
        return structuredResponse.normalizedStatements
    }

    // Retained temporarily for a manual rollback. This is intentionally not used as a fallback.
    private func atomize(_ caption: String, isRetry: Bool) async throws -> [String] {
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

    private func send(
        _ message: Message,
        through conversation: Conversation,
        responseFormat: ResponseFormat? = nil
    ) async throws -> Message {
        activeConversation = conversation
        defer {
            if activeConversation === conversation {
                activeConversation = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await conversation.sendMessage(message, responseFormat: responseFormat)
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancel()
            }
        }
    }
}

enum AtomizationResponseFormat {
    static func make() throws -> ResponseFormat {
        try ResponseFormat.json(
            schema: [
                "type": "object",
                "properties": [
                    "statements": [
                        "type": "array",
                        "items": ["type": "string"],
                        "minItems": 1
                    ]
                ],
                "required": ["statements"],
                "additionalProperties": false
            ]
        )
    }
}

nonisolated struct StructuredAtomizationResponse: Decodable, Sendable {
    let statements: [String]

    var normalizedStatements: [String] {
        var seen = Set<String>()
        return statements.compactMap { statement in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }
}

nonisolated enum AtomizationRetryPolicy {
    static let maximumAttempts = 2

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
        if error is DecodingError {
            return true
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.Code.propertyListReadCorrupt.rawValue {
            return true
        }

        if let structuredError = error as? StructuredAtomizationError {
            return structuredError == .noToolCall || structuredError == .multipleToolCalls
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
    case noToolCall
    case multipleToolCalls
    case missingCaptureContext
    case unableToEncodeInput

    var errorDescription: String? {
        switch self {
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
