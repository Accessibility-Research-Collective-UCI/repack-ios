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
        guard let capabilities = Capabilities(modelPath: modelURL.path),
              capabilities.hasSpeculativeDecodingSupport() else {
            throw REPACKError.modelDoesNotSupportSpeculativeDecoding
        }
    }

    func makeVisionEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = false
        ExperimentalFlags.visualTokenBudget = 1_120

        let configuration = try EngineConfig(
            modelPath: modelURL.path,
            backend: .gpu,
            visionBackend: .cpu(),
            maxNumTokens: 4_096,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: configuration)
        try await engine.initialize()
        return LiteRTREPACKInferenceEngine(engine: engine)
    }

    func makeTextEngine(modelURL: URL) async throws -> any REPACKInferenceEngine {
        ExperimentalFlags.optIntoExperimentalAPIs()

        ExperimentalFlags.enableSpeculativeDecoding = true

        let configuration = try EngineConfig(
            modelPath: modelURL.path,
            backend: .gpu,
            visionBackend: nil,
            maxNumTokens: 4_096,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: configuration)
        try await engine.initialize()
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

        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(REPACKPrompts.atomizePrompt, role: .system),
            tools: [SubmitAtomicStatementsTool()],
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        let sink = AtomicStatementsSink()
        let input = """
            Caption to atomize:
            <caption>
            \(trimmedCaption)
            </caption>
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
