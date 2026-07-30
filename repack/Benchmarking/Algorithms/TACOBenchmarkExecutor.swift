#if BENCHMARKING
import Foundation

@MainActor
final class TACOBenchmarkExecutor: BenchmarkAlgorithmExecuting {
    let algorithm = BenchmarkAlgorithm.taco
    let stages = BenchmarkAlgorithm.taco.stages

    private let prompt: String
    private let reformulationCount: Int
    private let visionEngine: any InferenceEngine
    private let textEngine: any InferenceEngine & BenchmarkTextGenerating
    private let clock = ContinuousClock()

    init(
        visionModelURL: URL,
        textModelURL: URL,
        prompt: String,
        reformulationCount: Int,
        engineFactory: any EngineFactory
    ) async throws {
        self.prompt = prompt
        self.reformulationCount = reformulationCount
        try engineFactory.validateModel(at: visionModelURL)
        try engineFactory.validateModel(at: textModelURL)
        visionEngine = try await engineFactory.makeVisionEngine(modelURL: visionModelURL)
        let engine = try await engineFactory.makeTextEngine(modelURL: textModelURL)
        guard let benchmarkTextEngine =
            engine as? any InferenceEngine & BenchmarkTextGenerating else {
            throw TACOError.unsupportedTextEngine
        }
        textEngine = benchmarkTextEngine
    }

    func process(
        image: URL,
        progress: @escaping @MainActor (BenchmarkAlgorithmProgress) -> Void
    ) async throws -> BenchmarkImageExecutionResult {
        var timings: [String: Double] = [:]

        progress(Self.progress("captioning", fraction: 0))
        let captionStart = clock.now
        let caption = try await visionEngine.generateCaption(
            image: image,
            prompt: prompt,
            seed: 1
        )
        timings["captioning"] = captionStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("captioning", fraction: 1))

        progress(Self.progress("tupleExtraction", fraction: 0))
        let tupleStart = clock.now
        let tuples = try await generateList(
            stage: "tuple extraction",
            systemPrompt: Self.tupleGenerationPrompt,
            userPrompt: caption,
            parser: Self.parseTuples
        )
        timings["tupleExtraction"] = tupleStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("tupleExtraction", fraction: 1))

        progress(Self.progress("queryGeneration", fraction: 0))
        let queryStart = clock.now
        let tupleInput = tuples.enumerated().map {
            "\($0.offset + 1) | \($0.element)"
        }.joined(separator: "\n")
        let questions = try await generateList(
            stage: "query generation",
            systemPrompt: Self.atomicQueryPrompt,
            userPrompt: tupleInput,
            parser: Self.parseQuestions
        )
        timings["queryGeneration"] = queryStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("queryGeneration", fraction: 1))

        let reformulationStart = clock.now
        var questionReformulations: [(question: String, reformulations: [String])] = []
        for (index, question) in questions.enumerated() {
            try Task.checkCancellation()
            progress(
                Self.progress(
                    "reformulation",
                    fraction: Double(index) / Double(questions.count)
                )
            )
            let reformulations = try await generateList(
                stage: "query reformulation",
                systemPrompt: "",
                userPrompt: Self.reformulationPrompt(
                    question: question,
                    count: reformulationCount
                ),
                parser: Self.parseQuestions
            )
            questionReformulations.append(
                (question, Array(reformulations.prefix(reformulationCount)))
            )
            progress(
                Self.progress(
                    "reformulation",
                    fraction: Double(index + 1) / Double(questions.count)
                )
            )
        }
        timings["reformulation"] =
            reformulationStart.duration(to: clock.now).benchmarkSeconds

        let verificationStart = clock.now
        let totalVerifications = questionReformulations.reduce(0) {
            $0 + $1.reformulations.count
        }
        var completedVerifications = 0
        var queryMetadata: [TACOQueryMetadata] = []
        progress(Self.progress("verification", fraction: 0))

        for item in questionReformulations {
            var verifications: [TACOVerificationMetadata] = []
            for reformulation in item.reformulations {
                try Task.checkCancellation()
                let response = try await visionEngine.generateCaption(
                    image: image,
                    prompt: """
                    Answer with exactly one lowercase word: yes or no.
                    Question: \(reformulation)
                    """,
                    seed: 1
                )
                verifications.append(
                    TACOVerificationMetadata(
                        reformulation: reformulation,
                        response: response
                    )
                )
                completedVerifications += 1
                progress(
                    Self.progress(
                        "verification",
                        fraction: Double(completedVerifications)
                            / Double(totalVerifications)
                    )
                )
            }

            let yesCount = verifications.count { Self.isYes($0.response) }
            let noCount = verifications.count - yesCount
            queryMetadata.append(
                TACOQueryMetadata(
                    question: item.question,
                    verifications: verifications,
                    yesCount: yesCount,
                    noCount: noCount,
                    confidence: Double(yesCount) / Double(verifications.count),
                    majorityAnswer: yesCount >= noCount ? "yes" : "no"
                )
            )
        }
        timings["verification"] =
            verificationStart.duration(to: clock.now).benchmarkSeconds

        progress(Self.progress("refinement", fraction: 0))
        let refinementStart = clock.now
        let refinedCaption = try await textEngine.generateText(
            systemPrompt: "",
            userPrompt: Self.refinementPrompt(
                question: prompt,
                answer: caption,
                queries: queryMetadata
            )
        )
        timings["refinement"] =
            refinementStart.duration(to: clock.now).benchmarkSeconds
        progress(Self.progress("refinement", fraction: 1))

        return BenchmarkImageExecutionResult(
            timing: BenchmarkImageTiming(
                file: image.lastPathComponent,
                totalTime: timings.values.reduce(0, +),
                stages: timings
            ),
            metadata: BenchmarkImageMetadata(
                file: image.lastPathComponent,
                details: .taco(
                    TACOBenchmarkMetadata(
                        originalCaption: caption,
                        atomicTuples: tuples,
                        queries: queryMetadata,
                        refinedCaption: refinedCaption
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            )
        )
    }

    func cancel() async {
        await visionEngine.cancel()
        await textEngine.cancel()
    }

    private func generateList(
        stage: String,
        systemPrompt: String,
        userPrompt: String,
        parser: (String) -> [String]
    ) async throws -> [String] {
        var lastError: (any Error)?
        for _ in 0...5 {
            try Task.checkCancellation()
            do {
                let response = try await textEngine.generateText(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt
                )
                let values = parser(response)
                if !values.isEmpty {
                    return values
                }
                lastError = TACOError.noValues(stage)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TACOError.noValues(stage)
    }

    nonisolated static func parseTuples(_ response: String) -> [String] {
        let pattern =
            #"(?:\"?tuple_type\"?)\s*:\s*\"([^\"]+)\"[\s\S]*?(?:\"?relevant_words\"?)\s*:\s*\[([^\]]+)\]"#
        let matches = captures(in: response, pattern: pattern)
        let structured = matches.compactMap { capture -> String? in
            guard capture.count == 2 else { return nil }
            let words = captures(
                in: capture[1],
                pattern: #"\"([^\"]+)\""#
            ).compactMap(\.first)
            let relevantWords = words.isEmpty
                ? capture[1].split(separator: ",").map {
                    cleanValue(String($0))
                }
                : words
            guard !capture[0].isEmpty, !relevantWords.isEmpty else { return nil }
            return "\(capture[0]) (\(relevantWords.joined(separator: ", ")))"
        }
        if !structured.isEmpty {
            return structured
        }

        return response.split(whereSeparator: \.isNewline).compactMap { line in
            let value = cleanValue(String(line))
            let lowercased = value.lowercased()
            guard ["entity -", "attribute -", "relation -", "other -"].contains(
                where: lowercased.contains
            ) else {
                return nil
            }
            return value
        }
    }

    nonisolated static func parseQuestions(_ response: String) -> [String] {
        let quoted = captures(
            in: response,
            pattern: #"["']([^"']+\?)["']"#
        ).compactMap(\.first)
        if !quoted.isEmpty {
            return quoted
        }

        return response.split(whereSeparator: \.isNewline).compactMap { line in
            let value = cleanValue(String(line))
            return value.contains("?") ? value : nil
        }
    }

    nonisolated static func isYes(_ response: String) -> Bool {
        response.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("yes")
    }

    private nonisolated static func captures(
        in value: String,
        pattern: String
    ) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: value) else {
                    return nil
                }
                return String(value[range])
            }
        }
    }

    private nonisolated static func cleanValue(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*(?:\d+\s*[.)|]|\-|\*)\s*"#,
            with: "",
            options: .regularExpression
        )
        if let pipe = cleaned.firstIndex(of: "|") {
            cleaned = String(cleaned[cleaned.index(after: pipe)...])
        }
        return cleaned.trimmingCharacters(
            in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\"',[]{}")
            )
        )
    }

    private static func progress(
        _ id: String,
        fraction: Double
    ) -> BenchmarkAlgorithmProgress {
        BenchmarkAlgorithmProgress(
            stage: BenchmarkAlgorithm.taco.stages.first { $0.id == id },
            fractionCompleted: fraction
        )
    }

    private static func reformulationPrompt(
        question: String,
        count: Int
    ) -> String {
        """
        Paraphrase the following question about an image maintaining the exact same meaning. You must keep the entity names in the paraphrased questions the same as in the input question to prevent any ambiguity. Ensure each generated question is easily understandable and can be answered with "yes" or "no." Generate \(count) distinct paraphrased versions of the question.

        Input question:
        ```
        \(question)
        ```

        Directly provide your paraphrased questions in a list without any explanations.
        """
    }

    private static func refinementPrompt(
        question: String,
        answer: String,
        queries: [TACOQueryMetadata]
    ) -> String {
        let verificationContext = queries.map {
            "\"\($0.question)\" (\($0.majorityAnswer))"
        }.joined(separator: ",\n")
        return """
        Given a VQA question-answer pair, refine the model's initial answer using the context of verification questions and their ground truth answers. Preserve the model's answer if the verification context confirms that the final answer is correct, even if the model's reasoning is flawed. Only revise the model's answer if the verification context provides highly specific and directly relevant evidence that the final answer itself is incorrect. If no sufficiently relevant verification questions are available, return the initial answer as the output. Ensure that all output text is derived from the initial answer or the provided context; do not generate any new, unverified information.

        Question: "\(question)"

        Model's initial answer: "\(answer)"

        Verification context:
        ```
        [
        \(verificationContext)
        ]
        ```

        Provide only the revised answer without any explanation or additional text.

        Example:
        Question: "Describe this image."

        Model's initial answer: "A blue motorcycle parked by paint chipped doors."

        Verification context:
        ```
        [
        "Is there a motorcycle?" (yes),
        "Are there some doors?" (yes),
        "Is the motorcycle blue?" (no),
        "Are the doors painted?" (yes),
        "Is the door paint chipped?" (yes),
        "Is the motorcycle parked?" (yes),
        "Is the motorcycle next to the doors?" (yes)
        ]
        ```

        Response:
        A motorcycle parked by paint chipped doors.
        """
    }

    private static let tupleGenerationPrompt = """
    Task: Based on the example input questions, the example output tuples, and the provided tuple taxonomy below, generate skill-specific tuples to help verify and refine the answer of the last input question.

    Requirements:
    1. Ensure the generated tuples fully capture the factual information of the input question, with each tuple representing a distinct atomic and positive statement. Subjective elements in the initial answer should be disregarded.
    2. If the input question is irrelevant to any category, output "None."
    3. You must remove any negative words including "not" and "no" from your generation regardless of whether it will result in the opposite meaning.
    4. Do not generate trivial tuples about the image itself such as "entity - whole (image)".
    5. Each tuple should be output in the following format: id | tuple

    Tuple taxonomy:
    ```
    Entity relationships:
    * entity - whole
    * entity - part

    Attribute relationships:
    * attribute - state
    * attribute - color
    * attribute - type
    * attribute - text rendering
    * attribute - material
    * attribute - shape
    * attribute - size
    * attribute - count
    * attribute - texture
    * attribute - style
    * attribute - temporal

    Relations:
    * relation - spatial
    * relation - action

    Miscellaneous:
    * other - other
    ```

    Example:
    Sentence:
    "A blue motorcycle parked by paint chipped doors."
    Response:
    {
    atomic_tuples : [
        {tuple_type : "entity - whole",
        relevant_words : [motorcycle]},
        {tuple_type : "entity - whole",
        relevant_words : [doors]},
        {tuple_type : "attribute - color",
        relevant_words : [motorcycle, blue]},
        {tuple_type : "attribute - state",
        relevant_words : [doors, painted]},
        {tuple_type : "attribute - state",
        relevant_words : [door paint, chipped]},
        {tuple_type : "attribute - state",
        relevant_words : [motorcycle, parked]},
        {tuple_type : "relation - spatial",
        relevant_words : [motorcycle, doors, next to]},
        ]
    }
    """

    private static let atomicQueryPrompt = """
    Task: Given the example input questions, skill-specific tuples, and the example output of generated binary questions, re-write each tuple from the last example into a standalone, positively framed natural language binary question.

    Requirements:
    1. Each binary question should be non-trivial for a vision model to verify. Exclude trivial tuples that do not help in verifying and refining the initial answer.
    2. Each binary question should be self-contained and answerable independently, without requiring knowledge of other binary questions.
    3. Generate one binary question only for the two or more tuples sharing the same meaning or the opposite meaning.
    4. Ensure the generated questions fully capture the factual information of the input question. Create additional binary questions if they are helpful and complementary for refining the initial answer.
    5. Treat conditional statements or given information in "Question:" as context that you don't need to ask questions from.
    6. You must generate positively framed questions and remove any negative words including "not" and "no" from your generation regardless of whether it will result in the opposite meaning. For example, instead of generating "is this artwork not created by Jacob?", you should always ask its corresponding positive question "is this artwork created by Jacob?"

    Output format: id | question

    Example:
    Tuples:
    ["entity - whole (motorcycle)",
        "entity - whole (doors)",
        "attribute - color (motorcycle, blue)",
        "attribute - state (doors, painted)",
        "attribute - state (door paint, chipped)",
        "attribute - state (motorcycle, parked)",
        "relation - spatial (motorcycle, doors, next to)"
    ]
    Response:
    {atomic_queries : [
        "Is there a motorcycle?",
        "Are there some doors?",
        "Is the motorcycle blue?",
        "Are the doors painted?",
        "Is the door paint chipped?",
        "Is the motorcycle parked?",
        "Is the motorcycle next to the doors?"
        ]
    }
    """
}

private enum TACOError: LocalizedError {
    case noValues(String)
    case unsupportedTextEngine

    var errorDescription: String? {
        switch self {
        case .noValues(let stage):
            String(localized: "TACO \(stage) produced no usable output after six attempts.")
        case .unsupportedTextEngine:
            String(localized: "The selected text engine does not support TACO.")
        }
    }
}
#endif
