import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import repack

@Suite("Model Downloads", .serialized)
struct ModelDownloadTests {
    @Test("Approved models remain pinned and dependencies are explicit")
    func approvedCatalog() {
        let e2B = DownloadableModel.e2b.descriptor
        let e4B = DownloadableModel.e4b.descriptor
        let embedding = DownloadableModel.embeddingGemma.descriptor
        let tokenizer = DownloadableModel.embeddingGemmaTokenizer.descriptor
        guard case .huggingFace(let e2BSource) = e2B.source,
              case .huggingFace(let e4BSource) = e4B.source,
              case .direct(let embeddingURL) = embedding.source,
              case .direct(let tokenizerURL) = tokenizer.source else {
            Issue.record("Catalog models used an unexpected source")
            return
        }

        #expect(e2BSource.revision == "9262660a1676eed6d0c477ab1a86344430854664")
        #expect(
            e2B.sha256
                == "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
        )
        #expect(
            e2BSource.xetHash
                == "ee3c29acd58e68bea04006a144cd2e40b3b34dcf5c08200a013744c518b15115"
        )
        #expect(e4BSource.revision == "f7ad3343bd6ebc9607f4dc3bc4f2398bd5749bc5")
        #expect(
            e4B.sha256
                == "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0"
        )
        #expect(
            e4BSource.xetHash
                == "7301453651814b29d434ca0d341e365e0e28dc811cb764d836995cae25b37f31"
        )
        #expect(e4B.dependencies == [.e2b])
        #expect(DownloadableModel.e4b.dependencyOrder == [.e2b, .e4b])
        #expect(embedding.sha256 == "84bb72b8944df79a0f3650a50798c75cab5b3c0c4abdaeb5d45871b7c53dd7c5")
        #expect(embeddingURL.absoluteString == "https://uci-repack.s3.us-west-2.amazonaws.com/"
            + "embeddinggemma-300m-bertscore-layer16-seq256-f32.tflite")
        #expect(
            tokenizerURL.absoluteString
                == "https://uci-repack.s3.us-west-2.amazonaws.com/sentencepiece.model"
        )
        #expect(
            tokenizer.sha256
                == "d6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7"
        )
        #expect(
            DownloadableModel.embeddingGemma.dependencyOrder
                == [.embeddingGemmaTokenizer, .embeddingGemmaIDFE2B, .embeddingGemmaIDFE4B, .embeddingGemma]
        )
        #expect(
            DownloadableModel.embeddingModels == [.embeddingGemma]
        )
    }

    @Test("Plans use Hub sizes and production skips an installed dependency")
    func metadataDrivenPlans() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let hub = FixtureModelHub(
            sizes: [
                DownloadableModel.e2b.fileName: 10,
                DownloadableModel.e4b.fileName: 20
            ]
        )
        let service = fixture.service(hub: hub)

        let debugPlan = try await service.preparePlan(
            for: .e4b,
            policy: .validateAndRemove
        )

        #expect(debugPlan.files.map(\.model) == [.e2b, .e4b])
        #expect(debugPlan.totalBytes == 30)
        #expect(debugPlan.confirmationMessage.contains("Both models"))

        try fixture.installModel(.e2b)
        let productionPlan = try await service.preparePlan(
            for: .e4b,
            policy: .install
        )

        #expect(productionPlan.files.map(\.model) == [.e4b])
        #expect(productionPlan.totalBytes == 20)
        #expect(productionPlan.dependencyAlreadyInstalled)
        #expect(productionPlan.confirmationMessage.contains("already downloaded"))
    }

    @Test("Embedding download includes the token model, tokenizer, and both calibrations")
    func embeddingModelPlan() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let models = DownloadableModel.embeddingGemma.dependencyOrder
        let hub = FixtureModelHub(sizes: Dictionary(uniqueKeysWithValues: models.map { ($0.fileName, Int64(10)) }))
        let service = fixture.service(hub: hub)
        let plan = try await service.preparePlan(for: .embeddingGemma, policy: .install)
        #expect(plan.files.map(\.model) == models)
        #expect(plan.totalBytes == 40)
    }

    @Test("Embedding installation requires the token model and both calibrations")
    func embeddingInstallationCompleteness() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let service = fixture.service(hub: FixtureModelHub())
        try fixture.installModel(.embeddingGemmaTokenizer)
        try fixture.installModel(.embeddingGemmaIDFE2B)
        try Data("old pooled model".utf8).write(to: fixture.modelsDirectory.appending(
            path: "embeddinggemma-300M_seq256_mixed-precision.tflite"
        ))
        #expect(await service.isInstalled(.embeddingGemma) == false)
        try fixture.installModel(.embeddingGemma)
        #expect(await service.isInstalled(.embeddingGemma) == false)
        try fixture.installModel(.embeddingGemmaIDFE4B)
        #expect(await service.isInstalled(.embeddingGemma))
    }

    @Test("Calibration filenames resolve before caption-model substring matching")
    func calibrationCatalog() {
        for model in [DownloadableModel.embeddingGemmaIDFE2B, .embeddingGemmaIDFE4B] {
            #expect(DownloadableModel(modelURL: URL(filePath: model.fileName)) == model)
            #expect(model.isEmbeddingDependency)
            #expect(model.descriptor.sha256.count == 64)
        }
    }

    @Test("Temporary Xet progress infers the reconstructed file length")
    func inferredFileProgress() throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.directory.appending(path: "partial.litertlm")
        try Data("abc".utf8).write(to: destination)

        let fraction = SwiftHuggingFaceModelHub.inferredProgress(
            at: destination,
            expectedByteCount: 6
        )

        #expect(fraction == 0.5)
    }

    @Test("A pre-cancelled direct download leaves no active work")
    func directDownloadImmediateCancellation() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let downloader = DirectHTTPDownloader()
        downloader.cancel()

        do {
            _ = try await downloader.download(
                from: URL(string: "https://example.invalid/model.tflite")!,
                expectedByteCount: 100,
                to: fixture.directory.appending(path: "cancelled.tflite"),
                progressHandler: { _ in }
            )
            Issue.record("Expected the direct download to be cancelled")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }

        #expect(!downloader.hasActiveWork)
    }

    @Test("Direct downloads clean up progress work after completion and failure")
    func directDownloadProgressCleanup() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let source = URL(string: "https://fixture.invalid/model.tflite")!
        let payload = Data("embedding-model".utf8)

        let successfulSession = DirectDownloadURLProtocol.session(
            statusCode: 200,
            data: payload
        )
        defer { successfulSession.invalidateAndCancel() }
        let successfulDownloader = DirectHTTPDownloader(
            session: successfulSession
        )
        let destination = fixture.directory.appending(path: "model.tflite")

        let downloadedURL = try await successfulDownloader.download(
            from: source,
            expectedByteCount: Int64(payload.count),
            to: destination,
            progressHandler: { _ in }
        )

        #expect(try Data(contentsOf: downloadedURL) == payload)
        #expect(!successfulDownloader.hasActiveWork)

        let failingSession = DirectDownloadURLProtocol.session(
            statusCode: 500,
            data: Data()
        )
        defer { failingSession.invalidateAndCancel() }
        let failingDownloader = DirectHTTPDownloader(session: failingSession)

        await #expect(throws: URLError.self) {
            _ = try await failingDownloader.download(
                from: source,
                expectedByteCount: 1,
                to: fixture.directory.appending(path: "failure.tflite"),
                progressHandler: { _ in }
            )
        }
        #expect(!failingDownloader.hasActiveWork)
    }

    @Test("Dependencies report progress in order")
    func dependencyProgress() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let firstData = Data("a".utf8)
        let secondData = Data("bc".utf8)
        let first = fixtureFile(model: .e2b, fileName: "first.litertlm", data: firstData)
        let second = fixtureFile(model: .e4b, fileName: "second.litertlm", data: secondData)
        let hub = FixtureModelHub(
            payloads: [
                first.descriptor.fileName: firstData,
                second.descriptor.fileName: secondData
            ],
            fractions: [0.5]
        )
        let service = fixture.service(hub: hub)
        let plan = DownloadPlan(
            requestedModel: .e4b,
            files: [first, second],
            dependencyAlreadyInstalled: false,
            policy: .validateAndRemove
        )
        let recorder = ProgressRecorder()

        let outcome = try await service.execute(plan) {
            await recorder.append($0)
        }
        let updates = await recorder.values

        #expect(outcome == .validatedAndRemoved)
        #expect(updates.first?.currentModel == .e2b)
        #expect(updates.contains { $0.currentModel == .e4b && $0.fileIndex == 2 })
        #expect(updates.last?.fractionCompleted == 1)
    }

    @Test("Debug deletes validated files and production promotes them")
    func debugDeletionAndProductionPromotion() async throws {
        let payload = Data("abc".utf8)
        let file = fixtureFile(
            model: .e2b,
            fileName: "fixture.litertlm",
            data: payload
        )
        let hub = FixtureModelHub(payloads: [file.descriptor.fileName: payload])

        let debugFixture = try ModelDownloadFixture()
        defer { debugFixture.cleanUp() }
        let debugService = debugFixture.service(hub: hub)
        let debugPlan = DownloadPlan(
            requestedModel: .e2b,
            files: [file],
            dependencyAlreadyInstalled: false,
            policy: .validateAndRemove
        )

        let debugOutcome = try await debugService.execute(debugPlan) { _ in }

        #expect(debugOutcome == .validatedAndRemoved)
        #expect(try fixtureContents(at: debugFixture.downloadsDirectory).isEmpty)
        #expect(try fixtureContents(at: debugFixture.modelsDirectory).isEmpty)

        let productionFixture = try ModelDownloadFixture()
        defer { productionFixture.cleanUp() }
        let productionService = productionFixture.service(hub: hub)
        let productionPlan = DownloadPlan(
            requestedModel: .e2b,
            files: [file],
            dependencyAlreadyInstalled: false,
            policy: .install
        )

        let productionOutcome = try await productionService.execute(productionPlan) { _ in }
        let expectedURL = productionFixture.modelsDirectory
            .appending(path: file.descriptor.fileName)

        #expect(productionOutcome == .installed(expectedURL))
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    @Test("Checksum is the only artifact integrity gate")
    func checksumValidation() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let payload = Data("abc".utf8)
        let descriptor = ModelDescriptor(
            model: .e2b,
            fileName: "invalid.litertlm",
            sha256: String(repeating: "0", count: 64),
            dependencies: [],
            source: .huggingFace(
                HuggingFaceModelSource(
                    namespace: "fixture",
                    name: "fixture",
                    revision: "fixture-revision",
                    xetHash: String(repeating: "0", count: 64)
                )
            )
        )
        let file = DownloadFile(
            descriptor: descriptor,
            byteCount: Int64(payload.count + 100)
        )
        let hub = FixtureModelHub(payloads: [descriptor.fileName: payload])
        let service = fixture.service(hub: hub)
        let plan = DownloadPlan(
            requestedModel: .e2b,
            files: [file],
            dependencyAlreadyInstalled: false,
            policy: .install
        )

        await #expect(throws: DownloadError.invalidChecksum(model: .e2b)) {
            try await service.execute(plan) { _ in }
        }
        #expect(try fixtureContents(at: fixture.downloadsDirectory).isEmpty)
        #expect(try fixtureContents(at: fixture.modelsDirectory).isEmpty)
    }

    @Test("Cancellation removes the partial Xet destination")
    func cancellationCleanup() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let file = fixtureFile(
            model: .e2b,
            fileName: "partial.litertlm",
            data: Data("abc".utf8)
        )
        let hub = CancellableFixtureModelHub()
        let service = fixture.service(hub: hub)
        let plan = DownloadPlan(
            requestedModel: .e2b,
            files: [file],
            dependencyAlreadyInstalled: false,
            policy: .install
        )
        let task = Task {
            try await service.execute(plan) { _ in }
        }

        while !(await hub.hasStarted) {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await service.cancelCurrentDownload()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await hub.wasCancelled)
        #expect(try fixtureContents(at: fixture.downloadsDirectory).isEmpty)
    }

    @Test("Launch cleanup removes abandoned transactions")
    func abandonedStagingCleanup() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let orphan = fixture.downloadsDirectory
            .appending(path: "orphan", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: orphan.appending(path: "partial.litertlm")
        )
        let service = fixture.service(hub: FixtureModelHub())

        await service.cleanStagingDirectory()

        #expect(FileManager.default.fileExists(atPath: fixture.downloadsDirectory.path))
        #expect(try fixtureContents(at: fixture.downloadsDirectory).isEmpty)
    }

    @Test("Insufficient storage fails using the Hub-reported size")
    func insufficientStoragePreflight() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let requiredBytes: Int64 = 100
        let hub = FixtureModelHub(
            sizes: [DownloadableModel.e2b.fileName: requiredBytes]
        )
        let service = ModelDownloadService(
            hub: hub,
            capacityProvider: FixedModelStorageCapacityProvider(bytes: 1),
            baseDirectory: fixture.directory
        )

        await #expect(
            throws: DownloadError.insufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: 1
            )
        ) {
            try await service.preparePlan(
                for: .e2b,
                policy: .install
            )
        }
    }

    @Test("Dependency ownership controls deletion defaults")
    @MainActor
    func dependencyOwnershipAndDeletion() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let defaultsName = "ModelOwnershipTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let e2BData = Data("a".utf8)
        let e4BData = Data("bc".utf8)
        let e2B = fixtureFile(
            model: .e2b,
            fileName: DownloadableModel.e2b.fileName,
            data: e2BData
        )
        let e4B = fixtureFile(
            model: .e4b,
            fileName: DownloadableModel.e4b.fileName,
            data: e4BData
        )
        let service = fixture.service(
            hub: FixtureModelHub(
                payloads: [
                    e2B.descriptor.fileName: e2BData,
                    e4B.descriptor.fileName: e4BData
                ]
            )
        )
        let manager = ModelLibrary(
            downloadService: service,
            installationDefaults: defaults
        )
        let plan = DownloadPlan(
            requestedModel: .e4b,
            files: [e2B, e4B],
            dependencyAlreadyInstalled: false,
            policy: .install
        )

        _ = try await manager.download(plan: plan) { _ in }
        let localModels = [
            LocalModel(
                url: fixture.modelsDirectory.appending(path: e2B.descriptor.fileName),
                isBundled: false,
                origin: .approved
            ),
            LocalModel(
                url: fixture.modelsDirectory.appending(path: e4B.descriptor.fileName),
                isBundled: false,
                origin: .approved
            )
        ]
        var items = manager.storageItems(from: localModels)
        let e2BItem = try #require(items.first { $0.record.model == .e2b })
        let e4BItem = try #require(items.first { $0.record.model == .e4b })

        #expect(!e2BItem.record.explicitlyOwned)
        #expect(e2BItem.record.requiredBy == [.e4b])
        #expect(e4BItem.record.explicitlyOwned)
        #expect(
            manager.deletionSelection(
                toggling: e4BItem,
                isSelected: true,
                current: [],
                items: items
            ) == [e2BItem.id, e4BItem.id]
        )
        #expect(
            manager.deletionPlan(
                selection: [e2BItem.id],
                items: items
            ).ids == [e2BItem.id, e4BItem.id]
        )

        manager.markExplicitOwnership(of: e2BItem.model)
        items = manager.storageItems(from: localModels)
        let explicitlyOwnedE2B = try #require(
            items.first { $0.record.model == .e2b }
        )
        let refreshedE4B = try #require(
            items.first { $0.record.model == .e4b }
        )

        #expect(explicitlyOwnedE2B.record.explicitlyOwned)
        #expect(
            manager.deletionSelection(
                toggling: refreshedE4B,
                isSelected: true,
                current: [],
                items: items
            ) == [refreshedE4B.id]
        )
    }

    @Test("Embedding model storage groups tokenizer and both calibrations")
    @MainActor
    func embeddingStorageGrouping() async throws {
        let fixture = try ModelDownloadFixture()
        defer { fixture.cleanUp() }
        let defaultsName = "EmbeddingOwnershipTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let tokenizerData = Data("tokenizer".utf8)
        let modelData = Data("embedding".utf8)
        let tokenizer = fixtureFile(
            model: .embeddingGemmaTokenizer,
            fileName: DownloadableModel.embeddingGemmaTokenizer.fileName,
            data: tokenizerData
        )
        let embedding = fixtureFile(
            model: .embeddingGemma,
            fileName: DownloadableModel.embeddingGemma.fileName,
            data: modelData
        )
        let calibrationFiles = [DownloadableModel.embeddingGemmaIDFE2B, .embeddingGemmaIDFE4B].map {
            fixtureFile(model: $0, fileName: $0.fileName, data: Data("calibration".utf8))
        }
        let manager = ModelLibrary(
            downloadService: fixture.service(
                hub: FixtureModelHub(
                    payloads: [
                        tokenizer.descriptor.fileName: tokenizerData,
                        embedding.descriptor.fileName: modelData,
                        calibrationFiles[0].descriptor.fileName: Data("calibration".utf8),
                        calibrationFiles[1].descriptor.fileName: Data("calibration".utf8)
                    ]
                )
            ),
            installationDefaults: defaults
        )
        let plan = DownloadPlan(
            requestedModel: .embeddingGemma,
            files: [tokenizer, embedding] + calibrationFiles,
            dependencyAlreadyInstalled: false,
            policy: .install
        )

        _ = try await manager.download(plan: plan) { _ in }
        let items = manager.storageItems(
            from: [
                LocalModel(
                    url: fixture.modelsDirectory.appending(
                        path: tokenizer.descriptor.fileName
                    ),
                    isBundled: false,
                    origin: .approved
                ),
                LocalModel(
                    url: fixture.modelsDirectory.appending(
                        path: embedding.descriptor.fileName
                    ),
                    isBundled: false,
                    origin: .approved
                )
            ] + calibrationFiles.map {
                LocalModel(url: fixture.modelsDirectory.appending(path: $0.descriptor.fileName),
                           isBundled: false, origin: .approved)
            }
        )
        let tokenizerItem = try #require(
            items.first { $0.record.model == .embeddingGemmaTokenizer }
        )
        let embeddingItem = try #require(
            items.first { $0.record.model == .embeddingGemma }
        )

        #expect(items.filter { $0.record.model?.isEmbeddingDependency == true }.count == 3)
        #expect(items.filter { $0.record.model?.isEmbeddingDependency == true }.allSatisfy {
            !$0.record.explicitlyOwned && $0.record.requiredBy == [.embeddingGemma]
        })
        #expect(tokenizerItem.record.requiredBy == [.embeddingGemma])
        #expect(
            manager.deletionSelection(
                toggling: embeddingItem,
                isSelected: true,
                current: [],
                items: items
            ) == Set(items.map(\.id))
        )
        #expect(
            manager.deletionPlan(
                selection: [tokenizerItem.id],
                items: items
            ).ids == Set(items.map(\.id))
        )
        #expect(
            manager.deletionSelection(
                toggling: tokenizerItem,
                isSelected: false,
                current: [embeddingItem.id, tokenizerItem.id],
                items: items
            ).isEmpty
        )
    }
}

@Suite("Model Download Background Execution", .serialized)
@MainActor
struct ModelDownloadBackgroundExecutionTests {
    @Test("Queued task starts and forwards progress")
    func queuedProgress() throws {
        let scheduler = FakeModelDownloadTaskScheduler()
        let coordinator = ModelDownloadExecutionCoordinator(scheduler: scheduler)
        let transactionID = UUID()
        var starts = 0

        let mode = coordinator.submit(
            transactionID: transactionID,
            totalBytes: 1_000,
            start: { starts += 1 },
            expiration: {}
        )

        #expect(mode == .backgroundProtected)
        #expect(starts == 1)
        let submission = try #require(scheduler.submissions.first)
        #expect(
            submission.identifier
                == ModelDownloadExecutionCoordinator.taskIdentifierPrefix
                    + transactionID.uuidString.lowercased()
        )
        let task = try #require(scheduler.lastTask)

        coordinator.report(testProgress(completedBytes: 500, totalBytes: 1_000))
        #expect(task.progress.completedUnitCount == 500)
        #expect(task.titleUpdates.last?.subtitle.contains("Gemma 4 E2B") == true)

        coordinator.complete(success: true)

        #expect(task.progress.completedUnitCount == 1_000)
        #expect(task.completions == [true])
    }

    @Test("Submission failures require foreground confirmation")
    func foregroundFallbacks() {
        let scheduler = FakeModelDownloadTaskScheduler()
        scheduler.submissionError = FixtureError.rejected
        let coordinator = ModelDownloadExecutionCoordinator(scheduler: scheduler)

        let mode = coordinator.submit(
            transactionID: UUID(),
            totalBytes: 1,
            start: {},
            expiration: {}
        )

        #expect(mode == .foregroundOnly)
        #expect(scheduler.submissions.count == 1)
    }

    @Test("Expiration cancels work")
    func expiration() throws {
        let scheduler = FakeModelDownloadTaskScheduler()
        let coordinator = ModelDownloadExecutionCoordinator(scheduler: scheduler)
        var expirations = 0
        _ = coordinator.submit(
            transactionID: UUID(),
            totalBytes: 1,
            start: {},
            expiration: { expirations += 1 }
        )
        let task = try #require(scheduler.lastTask)

        task.expire()
        coordinator.complete(success: false)

        #expect(expirations == 1)
        #expect(task.completions == [false])
    }
}

@Suite("Model Download Notifications", .serialized)
@MainActor
struct ModelDownloadNotificationTests {
    @Test("Authorization is requested only when undetermined")
    func contextualAuthorization() async {
        let undetermined = FakeModelDownloadNotificationCenter(status: .notDetermined)
        let undeterminedNotifier = ModelDownloadNotifier(center: undetermined)

        await undeterminedNotifier.requestAuthorizationIfNeeded()

        #expect(await undetermined.authorizationRequests == 1)

        let authorized = FakeModelDownloadNotificationCenter(status: .authorized)
        let authorizedNotifier = ModelDownloadNotifier(center: authorized)

        await authorizedNotifier.requestAuthorizationIfNeeded()

        #expect(await authorized.authorizationRequests == 0)
    }

    @Test("Only authorized successful completions create notifications")
    func completionAuthorization() async {
        let denied = FakeModelDownloadNotificationCenter(status: .denied)
        let deniedNotifier = ModelDownloadNotifier(center: denied)
        let didPostDenied = await deniedNotifier.notifyCompletion(message: "Finished")
        #expect(!didPostDenied)
        #expect(await denied.messages.isEmpty)

        let authorized = FakeModelDownloadNotificationCenter(status: .authorized)
        let authorizedNotifier = ModelDownloadNotifier(center: authorized)
        let didPostAuthorized = await authorizedNotifier.notifyCompletion(
            message: "Finished"
        )

        #expect(didPostAuthorized)
        #expect(await authorized.messages == ["Finished"])
    }
}

private actor ProgressRecorder {
    private(set) var values: [DownloadProgress] = []

    func append(_ progress: DownloadProgress) {
        values.append(progress)
    }
}

private actor FixtureModelHub: ModelHubDownloading {
    let sizes: [String: Int64]
    let payloads: [String: Data]
    let fractions: [Double]

    init(
        sizes: [String: Int64] = [:],
        payloads: [String: Data] = [:],
        fractions: [Double] = []
    ) {
        self.sizes = sizes
        self.payloads = payloads
        self.fractions = fractions
    }

    func fileSize(for descriptor: ModelDescriptor) throws -> Int64 {
        guard let size = sizes[descriptor.fileName] else {
            throw FixtureError.missingMetadata
        }
        return size
    }

    func download(
        _ descriptor: ModelDescriptor,
        byteCount: Int64,
        to destination: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        guard let payload = payloads[descriptor.fileName] else {
            throw FixtureError.missingPayload
        }
        try payload.write(to: destination)
        for fraction in fractions {
            try Task.checkCancellation()
            await progressHandler(fraction)
        }
        await progressHandler(1)
        return destination
    }

    func cancelDownload() {}
}

private actor CancellableFixtureModelHub: ModelHubDownloading {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func fileSize(for descriptor: ModelDescriptor) -> Int64 {
        3
    }

    func download(
        _ descriptor: ModelDescriptor,
        byteCount: Int64,
        to destination: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        try Data("partial".utf8).write(to: destination)
        hasStarted = true
        try await Task.sleep(for: .seconds(60))
        return destination
    }

    func cancelDownload() {
        wasCancelled = true
    }
}

private struct ModelDownloadFixture {
    let directory: URL

    init() throws {
        directory = URL.temporaryDirectory
            .appending(path: "ModelDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    var downloadsDirectory: URL {
        directory.appending(path: "ModelDownloads", directoryHint: .isDirectory)
    }

    var modelsDirectory: URL {
        directory.appending(path: "Models", directoryHint: .isDirectory)
    }

    func service(hub: any ModelHubDownloading) -> ModelDownloadService {
        ModelDownloadService(
            hub: hub,
            capacityProvider: UnlimitedModelStorageCapacityProvider(),
            baseDirectory: directory
        )
    }

    func installModel(_ model: DownloadableModel) throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: modelsDirectory.appending(path: model.fileName).path,
            contents: Data()
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct UnlimitedModelStorageCapacityProvider: ModelStorageCapacityProviding {
    func availableCapacity(at directory: URL) -> Int64? {
        Int64.max
    }
}

private struct FixedModelStorageCapacityProvider: ModelStorageCapacityProviding {
    let bytes: Int64

    func availableCapacity(at directory: URL) -> Int64? {
        bytes
    }
}

@MainActor
private final class FakeModelDownloadTaskScheduler: ContinuedProcessingTaskScheduling {
    struct Submission: Equatable {
        let identifier: String
        let title: String
        let subtitle: String
    }

    var supportsBackgroundGPU = true
    var submissionError: (any Error)?
    var submissions: [Submission] = []
    private(set) var lastTask: FakeModelDownloadTask?
    private var launchHandler: (@MainActor (any ContinuedProcessingTaskHandling) -> Void)?

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandling) -> Void
    ) -> Bool {
        self.launchHandler = launchHandler
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        submissions.append(
            Submission(identifier: identifier, title: title, subtitle: subtitle)
        )
        if let submissionError {
            throw submissionError
        }
        let task = FakeModelDownloadTask()
        lastTask = task
        launchHandler?(task)
    }

    func cancel(identifier: String) {}
}

@MainActor
private final class FakeModelDownloadTask: ContinuedProcessingTaskHandling {
    struct TitleUpdate: Equatable {
        let title: String
        let subtitle: String
    }

    let progress = Progress(totalUnitCount: 0)
    var completions: [Bool] = []
    var titleUpdates: [TitleUpdate] = []
    private var expirationHandler: (@MainActor () -> Void)?

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        expirationHandler = handler
    }

    func updateTitle(_ title: String, subtitle: String) {
        titleUpdates.append(TitleUpdate(title: title, subtitle: subtitle))
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func expire() {
        expirationHandler?()
    }
}

private actor FakeModelDownloadNotificationCenter: ModelDownloadNotificationCenter {
    let status: UNAuthorizationStatus
    private(set) var authorizationRequests = 0
    private(set) var messages: [String] = []

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func modelDownloadAuthorizationStatus() -> UNAuthorizationStatus {
        status
    }

    func requestModelDownloadAuthorization() -> Bool {
        authorizationRequests += 1
        return true
    }

    func addModelDownloadNotification(title: String, message: String) {
        messages.append(message)
    }
}

private func fixtureFile(
    model: DownloadableModel,
    fileName: String,
    data: Data
) -> DownloadFile {
    let digest = SHA256.hash(data: data).map { byte in
        let value = String(byte, radix: 16)
        return value.count == 1 ? "0\(value)" : value
    }
    .joined()
    let descriptor = ModelDescriptor(
        model: model,
        fileName: fileName,
        sha256: digest,
        dependencies: model == .e4b ? [.e2b] : [],
        source: .huggingFace(
            HuggingFaceModelSource(
                namespace: "fixture",
                name: "fixture",
                revision: "fixture-revision",
                xetHash: String(repeating: "0", count: 64)
            )
        )
    )
    return DownloadFile(
        descriptor: descriptor,
        byteCount: Int64(data.count)
    )
}

private func fixtureContents(at directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }
    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
}

@MainActor
private func testProgress(
    completedBytes: Int64,
    totalBytes: Int64
) -> DownloadProgress {
    DownloadProgress(
        requestedModel: .e4b,
        currentModel: .e2b,
        fileIndex: 1,
        fileCount: 2,
        completedBytes: completedBytes,
        totalBytes: totalBytes
    )
}

nonisolated private enum FixtureError: Error {
    case missingMetadata
    case missingPayload
    case rejected
}

nonisolated private final class DirectDownloadURLProtocol:
    URLProtocol,
    @unchecked Sendable {
    nonisolated(unsafe) private static var response = (
        statusCode: 200,
        data: Data()
    )

    static func session(
        statusCode: Int,
        data: Data
    ) -> URLSession {
        response = (statusCode, data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectDownloadURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: Self.response.statusCode,
                  httpVersion: nil,
                  headerFields: [
                      "Content-Length": "\(Self.response.data.count)"
                  ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
