#if BENCHMARKING
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct BenchmarkExportItem: Transferable, Sendable {
    let data: Data
    let filename: String

    init(output: BenchmarkOutput) {
        data = (try? output.formattedJSONData()) ?? Data("{}".utf8)
        filename = output.exportFilename
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let directory = FileManager.default.temporaryDirectory.appending(
                path: UUID().uuidString,
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appending(path: item.filename)
            try item.data.write(to: file, options: .atomic)
            return SentTransferredFile(file)
        }
        .suggestedFileName { $0.filename }
    }
}
#endif
