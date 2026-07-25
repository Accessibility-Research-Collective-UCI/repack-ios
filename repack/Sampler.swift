import Foundation
import LiteRTLM

@MainActor
struct Sampler {
    let engine: Engine

    func run(
        text: String,
        imageURL: URL?,
        sampleCount: Int,
        onSampleStarted: (Int, Int) -> Int,
        onTextDelta: (Int, String) -> Void,
        onTextComplete: (Int, String) -> Void,
        onTimingUpdate: @escaping (Int, Duration, Duration) -> Void,
        onSampleFinished: (Int, Duration, Duration) -> Void
    ) async throws {
        let clock = ContinuousClock()
        let totalStart = clock.now

        for sampleNumber in 1...sampleCount {
            let conversation = try await createConversation(seed: sampleNumber)
            let responseIndex = onSampleStarted(sampleNumber, sampleCount)
            let sampleStart = clock.now

            try await withTimingUpdates(
                clock: clock,
                sampleStart: sampleStart,
                totalStart: totalStart,
                responseIndex: responseIndex,
                onTimingUpdate: onTimingUpdate
            ) {
                let message = message(for: text, imageURL: imageURL)
                let response = try await conversation.sendMessage(message)
                onTextComplete(responseIndex, response.toString)
            }

            let now = clock.now
            onSampleFinished(
                responseIndex,
                sampleStart.duration(to: now),
                totalStart.duration(to: now)
            )
        }
    }

    private func createConversation(seed: Int) async throws -> Conversation {
        let sampler = try SamplerConfig(topK: 64, topP: 0.95, temperature: 1.0, seed: seed)
        let config = ConversationConfig(
            systemMessage: Message("Describe this image succinctly.", role: .system),
            samplerConfig: sampler,
        )
        return try await engine.createConversation(with: config)
    }

    private func withTimingUpdates(
        clock: ContinuousClock,
        sampleStart: ContinuousClock.Instant,
        totalStart: ContinuousClock.Instant,
        responseIndex: Int,
        onTimingUpdate: @escaping (Int, Duration, Duration) -> Void,
        operation: () async throws -> Void
    ) async throws {
        let timerTask = Task { @MainActor in
            do {
                while true {
                    try Task.checkCancellation()
                    let now = clock.now
                    onTimingUpdate(
                        responseIndex,
                        sampleStart.duration(to: now),
                        totalStart.duration(to: now)
                    )
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                // The operation completed or its parent task was cancelled.
            } catch {
                // Task.sleep(for:) only throws when cancellation is requested.
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await operation()
            } onCancel: {
                timerTask.cancel()
            }
            timerTask.cancel()
            await timerTask.value
        } catch {
            timerTask.cancel()
            await timerTask.value
            throw error
        }
    }

    private func message(for text: String, imageURL: URL?) -> Message {
        if let imageURL {
            var contents: [Content] = [.imageFile(imageURL.path)]
            if !text.isEmpty {
                contents.append(.text(text))
            }
            return Message(contents: contents)
        } else {
            return Message(text)
        }
    }
}
