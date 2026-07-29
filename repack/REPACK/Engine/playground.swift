#if DEBUG
@preconcurrency import LiteRTLM
import Foundation

private let playgroundQuestions = [
    "Is an aluminum can present?",
    "Does the image contain an aluminum can?",
    "Can an aluminum can be seen?",
    "Is there any aluminum can visible?",
    "Is an aluminum can visible in the image?",
    "Is there an aluminum can in the picture?",
    "Is an aluminum can shown?",
    "Is an aluminum can depicted?",
    "Is an aluminum can included in the image?",
    "Is an aluminum can observable?",
    "Is a Coca-Cola soda present?",
    "Does the image show a Coca-Cola soda?",
    "Can you see a Coca-Cola soda?",
    "Is there any Coca-Cola soda visible?",
    "Is a Coca-Cola soda visible in the image?",
    "Is there any sign of a Coca-Cola soda?",
    "Is a Coca-Cola soda included?",
    "Is a Coca-Cola soda depicted?",
    "Is there a Coca-Cola soda in the image?",
    "Is a Coca-Cola soda shown?",
    "Is the can constructed from aluminum?",
    "Is aluminum the material of the can?",
    "Is the can's composition aluminum?",
    "Is the can manufactured using aluminum?",
    "Is the can produced from aluminum?",
    "Is the can crafted out of aluminum?",
    "Is the can fabricated from aluminum?",
    "Is the can created using aluminum?",
    "Is the can built from aluminum?",
    "Is the can made out of aluminum?",
    "Is the can shown a Coca-Cola soda can?",
    "Is the can in the image a Coca-Cola soda can?",
    "Is the can depicted a Coca-Cola soda can?",
    "Is the can pictured a Coca-Cola soda can?",
    "Is the can displayed a Coca-Cola soda can?",
    "Is the can visible a Coca-Cola soda can?",
    "Is the can present a Coca-Cola soda can?",
    "Is the can featured a Coca-Cola soda can?",
    "Is the can in the photo a Coca-Cola soda can?",
    "Is the can being referred to a Coca-Cola soda can?",
    "Is the can colored red?",
    "Does the can have a red color?",
    "Is the color of the can red?",
    "Would you say the can is red?",
    "Is it true that the can is red?",
    "Is the can's color red?",
    "Can the can be described as red?",
    "Is the can visually red?",
    "Is the can red in appearance?",
    "Is the can red in color?",
    "Is the can colored white?",
    "Does the can have a white color?",
    "Is the color of the can white?",
    "Would you say the can is white?",
    "Is it true that the can is white?",
    "Can the can be described as white?",
    "Is the can's color white?",
    "Is the can considered white?",
    "Is the can visually white?",
    "Is the can white in appearance?",
    "Is there a polar bear design on the can?",
    "Does the can feature a polar bear design?",
    "Is a polar bear design present on the can?",
    "Does the can display a polar bear design?",
    "Is the can decorated with a polar bear design?",
    "Does the can show a polar bear design?",
    "Is a polar bear design depicted on the can?",
    "Does the can include a polar bear design?",
    "Is the can adorned with a polar bear design?",
    "Does the can have an image of a polar bear as its design?",
    "Is the polar bear design colored red and white?",
    "Does the polar bear design feature red and white colors?",
    "Are the colors of the polar bear design red and white?",
    "Is the polar bear design made up of red and white?",
    "Is the polar bear design in red and white?",
    "Does the polar bear design use red and white?",
    "Is the polar bear design shown in red and white?",
    "Are red and white the colors of the polar bear design?",
    "Is the polar bear design depicted in red and white?",
    "Is the polar bear design illustrated using red and white?"
]

private func seconds(_ duration: Duration) -> Double {
    let seconds = Double(duration.components.seconds)
    let attoseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    return seconds + attoseconds
}

private func formattedSeconds(_ elapsed: Double) -> String {
    "\(elapsed.formatted(.number.precision(.fractionLength(2))))s"
}

@MainActor
private func createPlaygroundVisionEngine(modelPath: String) async -> Engine {
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableConversationConstrainedDecoding = false
    ExperimentalFlags.enableSpeculativeDecoding = true
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

@MainActor
private func benchmarkVisionVerification(
    modelName: String,
    modelPath: String,
    imageData: Data
) async {
    let clock = ContinuousClock()
    let initializationStart = clock.now
    let engine = await createPlaygroundVisionEngine(modelPath: modelPath)
    let initializationTime = seconds(initializationStart.duration(to: clock.now))

    print("\n============ \(modelName) vision verification ============")
    print("Model initialization: \(formattedSeconds(initializationTime))")
    print("Queries: \(playgroundQuestions.count)")
    print("Speculative decoding: enabled")

    var queryTimes: [Double] = []
    queryTimes.reserveCapacity(playgroundQuestions.count)
    let wallClockStart = clock.now

    for (index, question) in playgroundQuestions.enumerated() {
        let samplingConfig = try! SamplerConfig(
            topK: 1,
            topP: 1,
            temperature: 0,
            seed: index + 1
        )
        let queryStart = clock.now
        let conversation = try! await engine.createConversation(
            with: ConversationConfig(samplerConfig: samplingConfig)
        )
        let prompt = """
            Answer with exactly one lowercase token: yes or no.
            Question: \(question)
            """
        let message = Message(
            contents: [
                .imageData(imageData),
                .text(prompt)
            ]
        )
        let rawAnswer = try! await conversation.sendMessage(message).toString
        let elapsed = seconds(queryStart.duration(to: clock.now))
        queryTimes.append(elapsed)

        let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validity = answer == "yes" || answer == "no" ? "" : " [INVALID ONE-TOKEN ANSWER]"
        print(
            "[\(index + 1)/\(playgroundQuestions.count)] "
                + "\(formattedSeconds(elapsed)) | \(answer.debugDescription)\(validity) | \(question)"
        )
    }

    let queryTotal = queryTimes.reduce(0, +)
    let wallClockTotal = seconds(wallClockStart.duration(to: clock.now))
    let average = queryTotal / Double(queryTimes.count)
    let minimum = queryTimes.min() ?? 0
    let maximum = queryTimes.max() ?? 0

    print("------------ \(modelName) summary ------------")
    print("Query inference total: \(formattedSeconds(queryTotal))")
    print("Query wall-clock total: \(formattedSeconds(wallClockTotal))")
    print("Average per query: \(formattedSeconds(average))")
    print("Minimum query: \(formattedSeconds(minimum))")
    print("Maximum query: \(formattedSeconds(maximum))")
    print("Model initialization: \(formattedSeconds(initializationTime))")
    print("Initialization + query wall clock: \(formattedSeconds(initializationTime + wallClockTotal))")
}

@MainActor
func runPlayground() async {
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
        string: "https://vizwiz.cs.colorado.edu/VizWiz_visualization_img/VizWiz_train_00012640.jpg"
    )!
    let (imageData, _) = try! await URLSession.shared.data(from: testImageURL)

    print("Loaded benchmark image: \(imageData.count) bytes")
    await benchmarkVisionVerification(
        modelName: "Gemma 4 E2B",
        modelPath: e2bPath,
        imageData: imageData
    )
    await benchmarkVisionVerification(
        modelName: "Gemma 4 E4B",
        modelPath: e4bPath,
        imageData: imageData
    )
}
#endif
