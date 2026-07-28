import Foundation
import SwiftUI

#Preview("Model Download Progress") {
    let model = AppModel()
    model.phase = .downloading(name: DownloadableModel.e4b.displayName, progress: 0.42)
    model.modelDownloadProgress = DownloadProgress(
        requestedModel: .e4b,
        currentModel: .e2b,
        fileIndex: 1,
        fileCount: 2,
        completedBytes: 2_624_025_940,
        totalBytes: 6_247_677_952
    )
    return ModelLibraryView(model: model)
}

#Preview("Model Selection") {
    let model = AppModel()
    model.localModels = [
        LocalModel(
            url: URL(fileURLWithPath: "/tmp/gemma-4-E2B-it.litertlm"),
            isBundled: true
        ),
        LocalModel(
            url: URL(fileURLWithPath: "/tmp/gemma-4-E4B-it.litertlm"),
            isBundled: true
        )
    ]
    return ModelSelectionView(model: model)
}
