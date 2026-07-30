#if BENCHMARKING
import Foundation

nonisolated enum BenchmarkCompletionState: String, Codable, Equatable, Sendable {
    case completed
    case interrupted
    case failed
}

nonisolated struct BenchmarkFailure: Codable, Equatable, Error, Sendable {
    enum Kind: String, Codable, Sendable {
        case cancelled
        case backgrounded
        case imageFailure
        case setupFailure
    }

    let kind: Kind
    let message: String
    let file: String?
}

nonisolated struct BenchmarkImageTiming: Codable, Equatable, Sendable {
    let file: String
    let totalTime: Double
    let stages: [String: Double]
}

nonisolated struct BenchmarkCaptionMetadata: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case reference
        case sample
    }

    let index: Int
    let type: Kind
    let text: String
    let atomics: [String]
}

nonisolated struct BenchmarkAtomicMatch: Codable, Equatable, Sendable {
    let sampleIndex: Int
    let statement: String?
    let score: Double
}

nonisolated struct BenchmarkAtomicMetadata: Codable, Equatable, Sendable {
    let statement: String
    let averageScore: Double
    let matches: [BenchmarkAtomicMatch]
}

nonisolated struct REPACKBenchmarkMetadata: Codable, Equatable, Sendable {
    let captions: [BenchmarkCaptionMetadata]
    let scoredAtomics: [BenchmarkAtomicMetadata]
    let retainedAtomics: [String]
    let finalCaption: String
}

nonisolated struct CapMASPropositionMetadata: Codable, Equatable, Sendable {
    let statement: String
    let score: Double
    let isTrue: Bool
}

nonisolated struct CapMASBenchmarkMetadata: Codable, Equatable, Sendable {
    let originalCaption: String
    let propositions: [CapMASPropositionMetadata]
    let truePropositions: [String]
    let falsePropositions: [String]
    let correctedCaption: String
}

nonisolated enum BenchmarkAlgorithmMetadata: Equatable, Sendable {
    case repack(REPACKBenchmarkMetadata)
    case capmas(CapMASBenchmarkMetadata)
}

nonisolated struct BenchmarkImageMetadata: Codable, Equatable, Sendable {
    let file: String
    let details: BenchmarkAlgorithmMetadata

    private enum CodingKeys: String, CodingKey {
        case file
        case algorithm
        case captions
        case scoredAtomics
        case retainedAtomics
        case finalCaption
        case originalCaption
        case propositions
        case truePropositions
        case falsePropositions
        case correctedCaption
    }

    init(file: String, details: BenchmarkAlgorithmMetadata) {
        self.file = file
        self.details = details
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        switch try container.decode(BenchmarkAlgorithm.self, forKey: .algorithm) {
        case .repack:
            details = .repack(
                REPACKBenchmarkMetadata(
                    captions: try container.decode(
                        [BenchmarkCaptionMetadata].self,
                        forKey: .captions
                    ),
                    scoredAtomics: try container.decode(
                        [BenchmarkAtomicMetadata].self,
                        forKey: .scoredAtomics
                    ),
                    retainedAtomics: try container.decode(
                        [String].self,
                        forKey: .retainedAtomics
                    ),
                    finalCaption: try container.decode(
                        String.self,
                        forKey: .finalCaption
                    )
                )
            )
        case .capmas:
            details = .capmas(
                CapMASBenchmarkMetadata(
                    originalCaption: try container.decode(
                        String.self,
                        forKey: .originalCaption
                    ),
                    propositions: try container.decode(
                        [CapMASPropositionMetadata].self,
                        forKey: .propositions
                    ),
                    truePropositions: try container.decode(
                        [String].self,
                        forKey: .truePropositions
                    ),
                    falsePropositions: try container.decode(
                        [String].self,
                        forKey: .falsePropositions
                    ),
                    correctedCaption: try container.decode(
                        String.self,
                        forKey: .correctedCaption
                    )
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        switch details {
        case .repack(let metadata):
            try container.encode(BenchmarkAlgorithm.repack, forKey: .algorithm)
            try container.encode(metadata.captions, forKey: .captions)
            try container.encode(metadata.scoredAtomics, forKey: .scoredAtomics)
            try container.encode(metadata.retainedAtomics, forKey: .retainedAtomics)
            try container.encode(metadata.finalCaption, forKey: .finalCaption)
        case .capmas(let metadata):
            try container.encode(BenchmarkAlgorithm.capmas, forKey: .algorithm)
            try container.encode(metadata.originalCaption, forKey: .originalCaption)
            try container.encode(metadata.propositions, forKey: .propositions)
            try container.encode(
                metadata.truePropositions,
                forKey: .truePropositions
            )
            try container.encode(
                metadata.falsePropositions,
                forKey: .falsePropositions
            )
            try container.encode(
                metadata.correctedCaption,
                forKey: .correctedCaption
            )
        }
    }
}

nonisolated struct BenchmarkResults: Codable, Equatable, Sendable {
    let totalTime: Double
    let averageTime: Double
    let shortestTime: Double
    let longestTime: Double
    let timing: [BenchmarkImageTiming]

    init(timing: [BenchmarkImageTiming]) {
        self.timing = timing
        let durations = timing.map(\.totalTime)
        totalTime = durations.reduce(0, +)
        averageTime = durations.isEmpty ? 0 : totalTime / Double(durations.count)
        shortestTime = durations.min() ?? 0
        longestTime = durations.max() ?? 0
    }
}

nonisolated struct BenchmarkOutput: Codable, Equatable, Sendable {
    let runStartTime: Date
    let runEndTime: Date
    let iPhoneModel: String
    let iPhoneIdentifier: String?
    let appVersion: String
    let buildVersion: String
    let osVersion: String
    let algorithm: BenchmarkAlgorithm
    let imageCount: Int
    let completedImageCount: Int
    let benchmarkSettings: BenchmarkSettings
    let results: BenchmarkResults
    let metadata: [BenchmarkImageMetadata]
    let status: BenchmarkCompletionState
    let failure: BenchmarkFailure?

    nonisolated var exportFilename: String {
        let settings = benchmarkSettings
        return [
            "benchmark-\(Self.filenameComponent(algorithm.rawValue))",
            Self.filenameComponent(iPhoneIdentifier ?? "unknown-device"),
            Self.filenameComponent(settings.visionEngine.model.rawValue),
            Self.filenameComponent(settings.textEngine.model.rawValue),
            Self.filenameComponent(settings.prompt.type.rawValue),
            "samples\(settings.numSamples)"
        ].joined(separator: "_") + ".json"
    }

    nonisolated func formattedJSONData() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    nonisolated func formattedJSON() -> String {
        (try? String(decoding: formattedJSONData(), as: UTF8.self)) ?? "{}"
    }

    private nonisolated static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private nonisolated static func filenameComponent(_ value: String) -> String {
        let pieces = value.lowercased().components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        let component = pieces.filter { !$0.isEmpty }.joined(separator: "-")
        return component.isEmpty ? "unknown" : component
    }
}
#endif
