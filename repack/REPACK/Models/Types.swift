import Foundation

nonisolated enum REPACKPrompts {
    static let productPrompt = """
    You are a helpful assistant who identifies products in images for blind and low-vision individuals. Identify the product in the image while following these guidelines:
    1: Identify crucial features about the product when visible, including:
    -- Object type (can, bag, plastic container, etc.)
    -- Product type (prepared or frozen meal, seasoning mix, soda, coffee)
    -- Brand (Heinz, Coca-Cola, Starbucks, etc.)
    -- Variety (specific flavors, sizes, count of items, etc.)
    -- Visual features (color, shape, size, etc.)
    2: Use clear, direct, and objective language. Do not use vague adjectives like 'large' or 'small', or vague adverbs like 'prominently' or 'clearly'.
    3: DO NOT mention camera artifacts (e.g., blur) or if an object is partially visible.
    4: DO NOT use introductory phrases (e.g., 'The image shows', 'The object is', 'The primary object is').

    Output only the final description of the product.
    """

    static let describePrompt = """
    You are a helpful assistant who describes images for blind and low-vision people using screen readers. Describe the image while following these guidelines:
    1: Use clear, direct, and objective language. Do not use vague adjectives like 'large' or 'small', or vague adverbs like 'prominently' or 'clearly'.
    2: DO NOT mention camera artifacts (e.g., blur) or if an object is partially visible.
    3: DO NOT use introductory phrases (e.g., 'The image shows', 'The object is', 'The primary object is').

    Output only the final description of the image.
    """

//    static let atomizePrompt = """
//    You are given a natural-language image description from a vision-language model.
//    Decompose it into independent, visually verifiable atomic facts.
//
//    Instructions:
//    1. Extract distinct elements (objects, relations, attributes, etc.).
//    2. Generate one simple, factual, unambiguous statement per atomic fact.
//
//    Guidelines:
//    - Each fact expresses only one visual detail.
//    - Avoid subjective words ("beautiful", "fancy"), inferred emotions, or multi-clause sentences.
//    - Use short, declarative sentences (e.g., "There is a dog." "A person wears a jacket.").
//    - Exclude speculative, temporal, or non-visual details.
//
//    Output Format:
//    Call submit_atomic_statements exactly once with the complete list. Do not return the statements as prose and do not add information that is not present in the caption.
//
//    ---
//
//    # Examples
//
//    Example 1
//    Input: A man posing for a selfie in a jacket and bow tie.
//
//    Output:
//    There is a man.
//    There is a jacket.
//    There is a bow tie.
//    A man is wearing a jacket.
//    A man is wearing a bow tie.
//    A man is posing for a selfie.
//
//    ---
//
//    Example 2
//    Input: The image features a red velvet couch with a cat lying on it.
//
//    Output:
//    There is a couch.
//    There is a cat.
//    The cat is lying on a couch.
//    The couch is red.
//    The couch is velvet.
//
//    ---
//
//    Example 3
//    Input: The photo is a close-up of a giraffe's head.
//
//    Output:
//    There is a giraffe.
//    There is a head.
//    The head belongs to a giraffe.
//
//    ---
//
//    Example 4
//    Input: A horse and several cows feed on hay.
//
//    Output:
//    There is a horse.
//    There are cows.
//    There are several cows.
//    There is hay.
//    A horse is feeding on hay.
//    Cows are feeding on hay.
//
//    ---
//
//    Example 5
//    Input: A red colored dog.
//
//    Output:
//    There is a dog.
//    The dog is red.
//
//    ---
//
//    Example 6
//    Input: Motorcyclists are parked outside a busy community center.
//
//    Output:
//    There are motorcyclists.
//    There is a community center.
//    Motorcycles are parked outside the community center.
//    The community center is busy.
//
//    ---
//
//    Example 7
//    Input: A can of Campbell's Tomato Soup with a red and white label and gold seal.
//
//    Output:
//    There is a can.
//    The can is Campbell's brand.
//    The can contains tomato soup.
//    The can has a label.
//    The label is red and white.
//    There is a seal on the can.
//    The seal is gold.
//    The label includes text that says 'Campbell's'.
//
//    ---
//
//    Example 8
//    Input: A bottle of shampoo on a bathroom counter next to a folded towel.
//
//    Output:
//    There is a bottle.
//    The bottle contains shampoo.
//    There is a counter.
//    The counter is in a bathroom.
//    The bottle is on the counter.
//    There is a towel.
//    The towel is folded.
//    The towel is next to the bottle.
//
//    ---
//
//    Example 9
//    Input: A bottle of soda with a blue label.
//
//    Output:
//    There is a bottle.
//    The bottle contains soda.
//    The bottle has a label.
//    The label is blue.
//
//    ---
//
//    Bad Example 1
//    Input: A cheerful person proudly showing off their new sneakers in a trendy park.
//
//    Incorrect Output (do NOT do this):
//    There is a cheerful person.
//    The person is proudly showing off sneakers.
//    The sneakers are new and expensive.
//    The person is in a trendy park.
//
//    Incorrect because:
//    - Contains subjective or inferred terms: "cheerful", "proudly", "expensive", "trendy".
//    - Mixes multiple ideas per statement (e.g., emotion + action + attribute).
//
//    Corrected Output:
//    There is a person.
//    The person is showing off sneakers.
//    The sneakers are new.
//    The person is in a park.
//
//    ---
//
//    Bad Example 2
//    Input: A coffee mug with a Starbucks logo, probably filled with latte foam.
//
//    Incorrect Output (do NOT do this):
//    There is a coffee mug.
//    The mug is from Starbucks.
//    The mug contains latte foam.
//
//    Incorrect because:
//    - "contains" overstates uncertain visual cues.
//
//    Corrected Output:
//    There is a coffee mug.
//    There is a Starbucks logo on the mug.
//    The mug may contain latte foam.
//    """
//
    static let atomizePrompt = """
    Decompose the following image description into visually verifiable atomic facts. Call `submit_atomic_statements` exactly once with the complete list. Return only the tool call.

    RULES:

    1. Express one visual detail per statement.
    2. Use only facts explicitly stated and visually verifiable.
    3. Remove subjective language, inferred emotions or intentions, and speculation.
    4. Use short, unambiguous, declarative sentences.

    EXAMPLES:

    Input: A red velvet couch with a cat lying on it.

    Statements:

    * There is a couch.
    * The couch is red.
    * The couch is velvet.
    * There is a cat.
    * The cat is lying on the couch.

    Input: A horse and several cows feed on hay.

    Statements:

    * There is a horse.
    * There are several cows.
    * There is hay.
    * The horse is feeding on hay.
    * The cows are feeding on hay.

    Input: A cheerful person proudly holding new sneakers, probably in a trendy park.

    Statements:

    * There is a person.
    * There are sneakers.
    * The person is holding the sneakers.
    """

    static let atomizeListPrompt = """
    You are given a natural-language image description from a vision-language model. Decompose it into independent atomic facts that capture visual details explicitly stated in the caption.

    Instructions:
    1. Extract distinct elements (objects, relations, attributes, etc.).
    2. Generate one simple, factual, unambiguous statement per atomic fact.

    Guidelines:
    - Each fact expresses only one visual detail.
    - Avoid subjective words ("beautiful", "fancy"), inferred emotions, or multi-clause sentences.
    - Use short, declarative sentences (e.g., "There is a dog.", "A person wears a jacket.").
    - Do not use parentheses, brackets, or optional wording. Write complete declarative sentences.
    - Exclude speculative, temporal, or non-visual details.
    - Do not add information that is not present in the caption.

    Output Format:
    Return only one valid JSON array of strings containing the complete list. Do not call a tool. Do not use Markdown fences, an object wrapper, or explanatory text. Use JSON double quotation marks only to delimit array strings. When quoting label text within a string, use single quotation marks.

    Example 1
    Input: A man posing for a selfie in a jacket and bow tie.
    Output: ["There is a man.", "There is a jacket.", "There is a bow tie.", "A man is wearing a jacket.", "A man is wearing a bow tie.", "A man is posing for a selfie."]

    Example 2
    Input: The image features a red velvet couch with a cat lying on it.
    Output:["There is a couch.", "There is a cat.", "The cat is lying on a couch.", "The couch is red.", "The couch is velvet."]

    Example 3
    Input: The photo is a close-up of a giraffe's head.
    Output:["There is a giraffe.", "There is a head.", "The head belongs to a giraffe."]

    Example 4
    Input: A horse and several cows feed on hay.
    Output: ["There is a horse.", "There are several cows.", "There is hay.", "A horse is feeding on hay.", "Cows are feeding on hay."]

    Example 5
    Input: A red colored dog.
    Output: ["There is a dog.", "The dog is red."]

    Example 6
    Input: Motorcyclists are parked outside a busy community center.
    Output: ["There are motorcyclists.", "There is a community center.", "Motorcycles are parked outside the community center.", "The community center is busy."]

    Example 7
    Input: A can of Campbell's Tomato Soup with a red and white label and gold seal.
    Output: ["There is a can.", "The can is Campbell's brand.", "The can contains tomato soup.", "The can has a label.", "The label is red and white.", "There is a seal on the can.", "The seal is gold."]

    Example 8
    Input: A bottle of shampoo on a bathroom counter next to a folded towel.
    Output: ["There is a bottle.", "The bottle contains shampoo.", "There is a counter.", "The counter is in a bathroom.", "The bottle is on the counter.", "There is a towel.", "The towel is folded.", "The towel is next to the bottle."]

    Example 9
    Input: A bottle of soda with a blue label.
    Output: ["There is a bottle.", "The bottle contains soda.", "The bottle has a label.", "The label is blue."]

    Example 10
    Input: A red and white Kellogg's cereal box. The label includes 32 oz and "GOOD SOURCE OF WHOLE GRAINS".
    Output: ["There is a box.", "The box is Kellogg's brand.", "The box is red and white.", "The label includes the text '32 oz'.", "The label includes the text 'GOOD SOURCE OF WHOLE GRAINS'."]

    Example 11
    Input: A box with the text "O'Bell's" on its label.
    Output: ["There is a box.", "The box has a label.", "The label includes the text O'Bell's."]

    Example 12
    Input: A bottle labeled "50% OFF" next to two blue towels.
    Output: ["There is a bottle.", "The bottle has a label.", "The label includes the text '50% OFF'.", "There are two towels.", "The towels are blue.", "The towels are next to the bottle."]

    Example 13
    Input: A black dog is not wearing a collar.
    Output: ["There is a dog.", "The dog is black.", "The dog is not wearing a collar."]

    Example 14
    Input: A blurry close-up photo of a red sign.
    Output: ["There is a sign.", "The sign is red.", "The photo is blurry.", "The photo is a close-up."]

    Example 15
    Input: A package of noodles or pasta.
    Output: ["There is a package.", "The package contains noodles or pasta."]
    """

    static let atomizeListRepairPrompt = """
    Repair the JSON syntax in the provided text. The intended value is one top-level JSON array \
    of strings. Return only the valid JSON array. Preserve every recoverable string exactly as \
    written and in the same order. Do not add, remove, reorder, or rewrite statements. Do not use \
    Markdown fences, an object wrapper, or explanatory text.
    """

    static let repackagePrompt = """
    You will be given a list of atomic statements that describe an image. Combine them into a single caption. Do not include any additional information. Output only the final caption.

    Example 1:
    Input:
    There is a dog.
    The dog is brown.
    The dog is wagging its tail.

    Output:
    A brown dog is wagging its tail.

    Example 2:
    Input:
    There is a bottle of soda.
    The bottle has a blue label.
    The label has text that says 'Coca-Cola'.

    Output:
    A bottle of soda with a blue label that says 'Coca-Cola'.
    """
}

nonisolated enum REPACKPrompt: Equatable, Sendable {
    case product
    case describe
    case custom(String)

    var resolvedText: String {
        switch self {
        case .product:
            REPACKPrompts.productPrompt
        case .describe:
            REPACKPrompts.describePrompt
        case .custom(let prompt):
            prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

nonisolated enum REPACKStage: Equatable, Hashable, Sendable {
    case sampling
    case atomizing
    case scoring
    case repackaging
}

nonisolated enum REPACKProgress: Equatable, Sendable {
    case preparingVisionModel
    case sampling(completed: Int, total: Int)
    case preparingTextModel
    case atomizing(completed: Int, total: Int)
    case scoring(completed: Int, total: Int)
    case repackaging
}

nonisolated struct REPACKCaption: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case reference
        case sample
    }

    let index: Int
    let kind: Kind
    let text: String

    var id: Int { index }
}

nonisolated enum REPACKAtomizationStatus: Equatable, Sendable {
    case parsed
    case unparseable
}

nonisolated struct REPACKAtomizationResult: Equatable, Sendable {
    let statements: [String]
    let status: REPACKAtomizationStatus
}

nonisolated struct REPACKAtomizedCaption: Equatable, Identifiable, Sendable {
    let caption: REPACKCaption
    let statements: [String]
    let status: REPACKAtomizationStatus

    var id: Int { caption.id }
}

nonisolated struct REPACKAtomicMatch: Equatable, Identifiable, Sendable {
    let sampleIndex: Int
    let statement: String?
    let score: Double

    var id: Int { sampleIndex }
}

nonisolated struct REPACKScoredAtomic: Equatable, Identifiable, Sendable {
    let index: Int
    let statement: String
    let matches: [REPACKAtomicMatch]
    let averageScore: Double

    var id: Int { index }
}

nonisolated struct REPACKStageTiming: Equatable, Identifiable, Sendable {
    let stage: REPACKStage
    let duration: Duration

    var id: REPACKStage { stage }
}

nonisolated struct REPACKResult: Equatable, Sendable {
    let captions: [REPACKCaption]
    let atomizedCaptions: [REPACKAtomizedCaption]
    let scoredAtomics: [REPACKScoredAtomic]
    let retainedAtomics: [String]
    let caption: String
    let threshold: Double
    let timings: [REPACKStageTiming]

    func replacingRepackage(
        retainedAtomics: [String],
        caption: String,
        threshold: Double,
        duration: Duration
    ) -> REPACKResult {
        var updatedTimings = timings.filter { $0.stage != .repackaging }
        updatedTimings.append(REPACKStageTiming(stage: .repackaging, duration: duration))

        return REPACKResult(
            captions: captions,
            atomizedCaptions: atomizedCaptions,
            scoredAtomics: scoredAtomics,
            retainedAtomics: retainedAtomics,
            caption: caption,
            threshold: threshold,
            timings: updatedTimings
        )
    }
}

nonisolated enum REPACKError: Error, Equatable, LocalizedError, Sendable {
    case invalidSampleCount(Int)
    case emptyPrompt
    case invalidThreshold(Double)
    case invalidModel
    case e4BUnavailableOnDevice
    case missingE2BProcessingModel
    case missingVisionEngine
    case missingTextEngine
    case noCachedResult
    case emptyModelResponse

    var errorDescription: String? {
        switch self {
        case .invalidSampleCount(let count):
            String(localized: "Sample count must be between 1 and 10. Received \(count).")
        case .emptyPrompt:
            String(localized: "Enter a prompt before captioning the image.")
        case .invalidThreshold:
            String(localized: "The threshold must be between 0 and 1.")
        case .invalidModel:
            String(localized: "The selected file is not a compatible LiteRT-LM model.")
        case .e4BUnavailableOnDevice:
            String(localized: "Gemma 4 E4B is not available on this iPhone.")
        case .missingE2BProcessingModel:
            String(localized: "Gemma 4 E2B is required to process captions sampled with E4B.")
        case .missingVisionEngine:
            String(localized: "The vision model is not ready.")
        case .missingTextEngine:
            String(localized: "The text model is not ready.")
        case .noCachedResult:
            String(localized: "Generate a caption before changing its threshold.")
        case .emptyModelResponse:
            String(localized: "The model returned an empty response.")
        }
    }
}
