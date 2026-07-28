#if DEBUG
@preconcurrency import LiteRTLM
import Foundation

/// Helper function to print time elapsed
private func formattedSeconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds)
    let attoseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    let elapsed = seconds + attoseconds

    return "\(elapsed.formatted(.number.precision(.fractionLength(2))))s"
}

// Creates engine for model.
@MainActor
func createEngineWithVision(
    modelPath: String,
    enableSpeculativeDecoding: Bool
) async -> Engine {
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableSpeculativeDecoding = enableSpeculativeDecoding
    ExperimentalFlags.visualTokenBudget = 1_120

    let config = try! EngineConfig(
        modelPath: modelPath,
        backend: .gpu,
        visionBackend: .gpu,
        maxNumTokens: 3_072,
        cacheDir: FileManager.default.temporaryDirectory.path
    )
    let engine = Engine(engineConfig: config)
    try! await engine.initialize()
    return engine
}

/// Generates n samples for a given model, prompt with image and text, and  speculative decoding setting.
@MainActor
func generateSamples(
    modelPath: String,
    message: Message,
    enableSpeculativeDecoding: Bool,
    n: Int
) async {
    print("------------ Generating \(n) captions with Speculative Decoding: \(enableSpeculativeDecoding) ------------")
    let engine = await createEngineWithVision(
        modelPath: modelPath,
        enableSpeculativeDecoding: enableSpeculativeDecoding
    )

    let clock = ContinuousClock()
    let totalStart = clock.now
    for sampleNum in 1...n {
        let start = clock.now
        let samplingConfig = try! SamplerConfig(
            topK: 64,
            topP: 0.95,
            temperature: 1.0,
            seed: sampleNum
        )
        let conversation = try! await engine.createConversation(
            with: ConversationConfig(samplerConfig: samplingConfig)
        )
        let caption = try! await conversation.sendMessage(message).toString

        print("Sample \(sampleNum) (\(formattedSeconds(start.duration(to: clock.now)))): \(caption)")
    }

    print("Total time: \(formattedSeconds(totalStart.duration(to: clock.now)))")
}

/// Applies sampling to Gemma 4 E2B and E4B, with speculative decoding disabled/enabled.
@MainActor
func runSampling() async {
    let e2bPath = Bundle.main.path(
        forResource: "gemma-4-E2B-it",
        ofType: "litertlm",
        inDirectory: "DevelopmentModels"
    )!
    let e4bPath = Bundle.main.path(
        forResource: "gemma-4-E4B-it",
        ofType: "litertlm",
        inDirectory: "DevelopmentModels"
    )!

    let testImageURL = URL(
        string: "https://upload.wikimedia.org/wikipedia/commons/0/0b/Cat_test.png?_=20220918031203"
    )!
    let captionPrompt = "Generate a short description of the image."

    let (imageData, _) = try! await URLSession.shared.data(from: testImageURL)
    let message = Message(
        contents: [
            .imageData(imageData),
            .text(captionPrompt)
        ]
    )
    let n_samples: Int = 5

    print("============ E2B ============")
    await generateSamples(
        modelPath: e2bPath,
        message: message,
        enableSpeculativeDecoding: false,
        n: n_samples
    )
    await generateSamples(
        modelPath: e2bPath,
        message: message,
        enableSpeculativeDecoding: true,
        n: n_samples
    )
    print("\n")

    print("============ E4B ============")
    await generateSamples(
        modelPath: e4bPath,
        message: message,
        enableSpeculativeDecoding: false,
        n: n_samples
    )
    await generateSamples(
        modelPath: e4bPath,
        message: message,
        enableSpeculativeDecoding: true,
        n: n_samples
    )
}
#endif
