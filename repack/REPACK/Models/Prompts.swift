import Foundation

nonisolated enum Prompts {
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

    static let hedgePrompt = """
    Rewrite the provided unverified visual statements as concise, cautious prose for a blind or low-vision reader.

    Requirements:
    1. Preserve every factual claim in the input. Do not omit, add, infer, correct, or elaborate on any detail. Copy quoted text exactly, including its quotation marks, and do not add punctuation inside a quote.
    2. Use only these hedge phrases: "may", "might", "possibly", "appears to", "appear to", "seems to", and "seem to". Write them as plain text without asterisks or other formatting.
    3. Keep every claim clearly within the scope of a hedge. Use the fewest hedge phrases needed: one hedge should cover related details about the same subject.
    4. Combine statements about the same entity into fluent prose. Prefer modifiers and compact lists over repeating the entity or hedge for every statement. Repeat a hedge only when the subject changes or the earlier hedge no longer clearly applies.
    5. Preserve each claim's grammatical roles and ownership. Do not create new relationships, resolve ambiguities, or change which entities the claims refer to.
    6. Do not mention verification, confidence, uncertainty scores, thresholds, atomic statements, algorithms, or models.
    7. Output only the rewritten prose, with no introduction, explanation, labels, or formatting.

    Do not write: The bag may be blue, may have a red label, and may contain crackers.
    Write: The bag may be blue, have a red label, and contain crackers.

    Do not write: There may be a bottle that may have a black cap and may display a white logo.
    Write: There may be a bottle with a black cap and a white logo.

    Example 1
    Input:
    There is a beer bottle.
    The beer bottle is made of glass.
    The beer bottle is brown.
    The beer bottle has a gold cap.
    The beer bottle has a yellow label.
    The label features a crown design.
    The label has text that reads "Walker's".
    The word "AMBER" is below the text "Walker's" on the label.

    Output:
    There may be a brown glass beer bottle with a gold cap and a yellow label; the label may feature a crown design, the text "Walker's", and the word "AMBER" below it.

    Example 2
    Input:
    There is a box.
    The box contains 18 K-Cups.
    The K-Cups are Keurig Brewed brand.
    The K-Cups are Vanilla Biscotti flavored.
    The box has a net weight of 5.71 ounces.
    The box has a net weight of 162 grams.
    The box has a black and silver design.
    There is an image of coffee beans on the box.
    The image is at the top left of the box.

    Output:
    There may be a black and silver box containing 18 Keurig Brewed Vanilla Biscotti-flavored K-Cups with a net weight of 5.71 ounces (162 grams) and an image of coffee beans at the top left.

    Example 3
    Input:
    There is a white plastic container.
    The container holds 100 ibuprofen tablets.
    The label has the Walgreens brand name.
    The label says "IBUPROFEN" in large yellow letters.
    The label says "Ibuprofen Tablets USP 200mg".
    The label says "Pain Reliever/Fever Reducer (NSAID)".
    The label says "TABLETS 100 TABLETS" at the bottom.

    Output:
    There may be a white plastic container holding 100 ibuprofen tablets with a label that may feature the Walgreens brand name, "IBUPROFEN" in large yellow letters, "Ibuprofen Tablets USP 200mg", "Pain Reliever/Fever Reducer (NSAID)", and "TABLETS 100 TABLETS" at the bottom.

    Example 4
    Input:
    There is a can.
    The can is red.
    The can has text that reads "TOMATO SAUCE".
    There is a packet next to the can.
    The packet is clear.
    The packet has a white label.

    Output:
    There may be a red can with the text "TOMATO SAUCE". Next to it, there may be a clear packet with a white label.
    """

    static let confidenceGroupPrompt = """
    Rewrite the provided image statements as one concise, natural sentence for a blind or low-vision reader. You will also be given the exact phrase that must begin the sentence.

    Requirements:
    1. Begin with the required prefix phrase exactly as written, and make it flow grammatically into the rest of the sentence.
    2. Preserve every factual claim. Do not omit, add, infer, correct, elaborate on, or repeat any detail.
    3. Combine closely related claims into fluent prose. Recast properties as modifiers, merge statements about the same entity, and consolidate lists. Do not merely join the input sentences with commas or "and."
    4. Preserve each claim's grammatical roles and ownership. Do not move an attribute, action, label, or contained item from one entity to another.
    5. Do not create new relationships, resolve ambiguities, or change which entities the claims refer to.
    6. Do not add hedging language such as "may," "might," "possibly," "probably," "appears," or "seems." The required prefix phrase is the only uncertainty language.
    7. Output only the rewritten sentence, with no introduction, explanation, headings, labels, bullet points, or formatting.

    Example 1
    Required prefix phrase:
    We think it is highly likely that

    Statements:
    There is a beer bottle.
    The beer bottle is made of glass.
    The beer bottle is brown.
    The beer bottle has a cap.
    The cap is gold.
    The beer bottle has a label.
    The label is yellow.
    The label features a crown design.
    The label has text that reads "Walker's".
    The word "AMBER" is below the text "Walker's" on the label.

    Output:
    We think it is highly likely that there is a brown glass beer bottle with a gold cap and a yellow label featuring a crown design, the text "Walker's," and the word "AMBER" below it.

    Example 2
    Required prefix phrase:
    We think it is somewhat likely that

    Statements:
    There is a box.
    The box contains K-Cups.
    The K-Cups are Keurig Brewed brand.
    The K-Cups are Vanilla Biscotti flavored.
    The box contains 18 K-Cups.
    The box has a net weight of 5.71 ounces.
    The box has a net weight of 162 grams.
    The box has a black and silver design.
    There is an image of coffee beans on the box.
    The image of coffee beans is at the top left of the box.

    Output:
    We think it is somewhat likely that there is a black and silver box containing 18 Keurig Brewed Vanilla Biscotti-flavored K-Cups with a net weight of 5.71 ounces (162 grams) and an image of coffee beans at the top left.

    Example 3
    Required prefix phrase:
    We are unsure whether

    Statements:
    There is a frozen patty burger.
    The burger has toppings.
    The burger is on cardboard packaging.
    The packaging includes text for "BEAN".
    The packaging includes text for "burger".
    The packaging includes nutritional information.
    The patty is dark brown.
    There is lettuce on the patty.
    There are diced tomatoes on the patty.
    There is corn on the patty.
    There are slices of jalapeño peppers on the patty.
    There is a plain bun piece.
    The plain bun piece is to the left of the patty.

    Output:
    We are unsure whether there is a frozen dark brown patty burger topped with lettuce, diced tomatoes, corn, and sliced jalapeño peppers on cardboard packaging with the text "BEAN" and "burger," nutritional information, and a plain bun piece to the left of the patty.
    """
}
