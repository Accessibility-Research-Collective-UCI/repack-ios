import Foundation

/// Downloads a direct model artifact while keeping cancellation and progress
/// observation scoped to the active URL session task.
nonisolated final class DirectHTTPDownloader: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private var task: URLSessionDownloadTask?
    private var progressMonitor: Task<Void, Never>?
    private var isCancelled = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    var hasActiveWork: Bool {
        lock.withLock {
            task != nil || progressMonitor != nil
        }
    }

    func download(
        from source: URL,
        expectedByteCount: Int64,
        to destination: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: source) {
                    [weak self]
                    temporaryURL,
                    response,
                    error in
                    self?.finish()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let response = response as? HTTPURLResponse,
                          200..<300 ~= response.statusCode,
                          let temporaryURL else {
                        continuation.resume(
                            throwing: URLError(.badServerResponse)
                        )
                        return
                    }

                    do {
                        try FileManager.default.moveItem(
                            at: temporaryURL,
                            to: destination
                        )
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let monitor = progressMonitor(
                    for: task,
                    expectedByteCount: expectedByteCount,
                    progressHandler: progressHandler
                )
                let shouldCancel = lock.withLock {
                    self.task = task
                    progressMonitor = monitor
                    return isCancelled
                }
                if shouldCancel {
                    task.cancel()
                    monitor.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            task?.cancel()
            progressMonitor?.cancel()
            task = nil
            progressMonitor = nil
        }
    }

    private func progressMonitor(
        for task: URLSessionDownloadTask,
        expectedByteCount: Int64,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                switch task.state {
                case .completed, .canceling:
                    return
                case .running:
                    let total = task.countOfBytesExpectedToReceive > 0
                        ? task.countOfBytesExpectedToReceive
                        : expectedByteCount
                    if total > 0 {
                        await progressHandler(
                            min(
                                max(
                                    Double(task.countOfBytesReceived)
                                        / Double(total),
                                    0
                                ),
                                0.999
                            )
                        )
                    }
                case .suspended:
                    break
                @unknown default:
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private func finish() {
        lock.withLock {
            progressMonitor?.cancel()
            progressMonitor = nil
            task = nil
        }
    }
}
