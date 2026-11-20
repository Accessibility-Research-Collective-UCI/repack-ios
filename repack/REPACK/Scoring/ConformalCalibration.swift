import Foundation
import CryptoKit

/// The exported Python risk grid. Thresholds are scores, not probabilities.
nonisolated struct ConformalCalibration: Equatable, Sendable {
    static let filename = "conformal_calibration.json"
    let thresholds: [Double]

    init(data: Data, model: DownloadableModel) throws {
        struct Export: Decodable {
            let similarity_key: String
            let delta: Double
            let models: [String: Table]
            struct Table: Decodable {
                let risk_tolerances: [Double]
                let proposed_thresholds: [Double]
            }
        }
        let export = try JSONDecoder().decode(Export.self, from: data)
        guard export.similarity_key == "atomic_similarity", export.delta == 0.05,
              model == .e2b || model == .e4b else { throw CalibrationError.invalid }
        for key in ["gemma-4-e2b", "gemma-4-e4b"] {
            guard let table = export.models[key],
                  table.risk_tolerances == (0...1000).map({ Double($0) / 1000 }),
                  table.proposed_thresholds.count == 1001,
                  table.proposed_thresholds.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  zip(table.proposed_thresholds, table.proposed_thresholds.dropFirst()).allSatisfy({ $0 >= $1 })
            else { throw CalibrationError.invalid }
        }
        guard let table = export.models[model == .e2b ? "gemma-4-e2b" : "gemma-4-e4b"] else {
            throw CalibrationError.invalid
        }
        thresholds = table.proposed_thresholds
    }

    @concurrent static func load(model: DownloadableModel) async throws -> Self {
        let directory = try ModelLibrary.modelsDirectory(fileManager: .default)
        let installed = directory.appending(path: filename)
        let bundled = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "DevelopmentModels")
        let url = FileManager.default.fileExists(atPath: installed.path) ? installed : (bundled ?? installed)
        do {
            let data = try Data(contentsOf: url)
            guard hasExpectedDigest(data) else { throw CalibrationError.invalid }
            return try Self(data: data, model: model)
        } catch {
            throw CalibrationError.unavailable(error)
        }
    }

    static func hasExpectedDigest(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            == DownloadableModel.conformalCalibration.descriptor.sha256
    }

    func threshold(certainty: Int) -> Double {
        precondition((0...100).contains(certainty))
        return thresholds[(100 - certainty) * 10]
    }

    func percentage(score: Double) -> Int {
        // Match searchsorted(-thresholds, -score, side="left") and Python's ties-to-even rounding.
        let index = thresholds.firstIndex { $0 <= score } ?? 1000
        return Int((100 * (1 - Double(index) / 1000)).rounded(.toNearestOrEven))
    }
}

nonisolated enum CalibrationError: LocalizedError {
    case invalid
    case unavailable(any Error)
    var errorDescription: String? {
        String(localized: .calibrationInvalid)
    }
}
