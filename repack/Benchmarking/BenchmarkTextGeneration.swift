#if BENCHMARKING
@preconcurrency import LiteRTLM

@MainActor
protocol BenchmarkTextGenerating: AnyObject {
    func generateText(systemPrompt: String, userPrompt: String) async throws -> String
}

extension LiteRTInferenceEngine: BenchmarkTextGenerating {
    func generateText(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        let sampler = try SamplerConfig(topK: 1, topP: 1, temperature: 0)
        let configuration = ConversationConfig(
            systemMessage: Message(systemPrompt, role: .system),
            samplerConfig: sampler
        )
        let conversation = try await engine.createConversation(with: configuration)
        return try await withTaskCancellationHandler {
            try await conversation.sendMessage(Message(userPrompt)).toString
        } onCancel: {
            Task { @MainActor in
                try? conversation.cancel()
            }
        }
    }
}
#endif
