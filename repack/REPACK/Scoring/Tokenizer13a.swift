import Foundation

/// The case-sensitive Moses/mteval-v13a tokenizer used by `BLEU`.
nonisolated enum Tokenizer13a {
    private static let alwaysSeparatedASCII: Set<UInt8> = {
        var characters = Set<UInt8>()
        characters.formUnion(32...38)
        characters.formUnion(40...43)
        characters.insert(47)
        characters.formUnion(58...64)
        characters.formUnion(91...96)
        characters.formUnion(123...126)
        return characters
    }()

    static func tokenize(_ line: String) throws -> [String] {
        let normalized = line
            .replacingOccurrences(of: "<skipped>", with: "")
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        let characters = Array(normalized)
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for (offset, index) in characters.indices.enumerated() {
            if offset.isMultiple(of: 1_024) {
                try Task.checkCancellation()
            }

            let character = characters[index]
            if character.isWhitespace {
                flushCurrent()
            } else if let ascii = character.asciiValue,
                      alwaysSeparatedASCII.contains(ascii) {
                flushCurrent()
                tokens.append(String(character))
            } else if character == "." || character == "," {
                let previous = index > characters.startIndex ? characters[index - 1] : nil
                let next = index < characters.index(before: characters.endIndex)
                    ? characters[index + 1]
                    : nil
                let separates = previous.map { !$0.isASCIIDigit } ?? false
                    || next.map { !$0.isASCIIDigit } ?? false
                if separates {
                    flushCurrent()
                    tokens.append(String(character))
                } else {
                    current.append(character)
                }
            } else if character == "-",
                      index > characters.startIndex,
                      characters[index - 1].isASCIIDigit {
                flushCurrent()
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }

        flushCurrent()
        return tokens
    }
}

private nonisolated extension Character {
    var isASCIIDigit: Bool {
        guard let asciiValue else { return false }
        return (48...57).contains(asciiValue)
    }
}
