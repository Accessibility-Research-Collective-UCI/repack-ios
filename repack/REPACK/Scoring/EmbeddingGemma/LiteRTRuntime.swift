import Darwin
import Foundation

// These declarations mirror the stable LiteRT C ABI exported by the LiteRT
// runtime already linked through CLiteRTLM. Embedding inference does not use
// the LiteRT-LM generation API.
private typealias LiteRTStatus = Int32
private typealias LiteRTType = Int32
private nonisolated let liteRTOk: LiteRTStatus = 0
private nonisolated let liteRTFloat32: LiteRTType = 1
private nonisolated let liteRTInt32: LiteRTType = 2

// EmbeddingGemmaService owns this wrapper and serializes every invocation.
nonisolated final class LiteRTEmbeddingInterpreter: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let xnnpackDelegate: UnsafeMutableRawPointer
    private let api: LiteRTAPI
    private let embeddingDimension: Int

    init(
        modelURL: URL,
        threadCount: Int,
        sequenceLength: Int,
        embeddingDimension: Int
    ) throws {
        let api: LiteRTAPI
        do {
            api = try LiteRTAPI()
        } catch {
            throw SemanticScoringError.runtimeFailure
        }

        let model = modelURL.path(percentEncoded: false).withCString {
            api.modelCreateFromFile($0)
        }
        guard let model else {
            throw SemanticScoringError.runtimeFailure
        }
        defer { api.modelDelete(model) }

        guard let options = api.optionsCreate() else {
            throw SemanticScoringError.runtimeFailure
        }
        defer { api.optionsDelete(options) }
        api.optionsSetNumThreads(options, Int32(threadCount))

        guard let xnnpackDelegate = REPACKCreateXNNPackDelegate(
            UnsafeMutableRawPointer(options),
            Int32(threadCount)
        ) else {
            throw SemanticScoringError.runtimeFailure
        }
        var ownsDelegate = true
        defer {
            if ownsDelegate {
                REPACKDeleteXNNPackDelegate(xnnpackDelegate)
            }
        }

        guard let interpreter = api.interpreterCreate(model, options) else {
            throw SemanticScoringError.runtimeFailure
        }
        var ownsInterpreter = true
        defer {
            if ownsInterpreter {
                api.interpreterDelete(interpreter)
            }
        }

        guard api.allocateTensors(interpreter) == liteRTOk else {
            throw SemanticScoringError.runtimeFailure
        }
        try Self.validateSignature(
            interpreter: interpreter,
            api: api,
            sequenceLength: sequenceLength,
            embeddingDimension: embeddingDimension
        )

        pointer = interpreter
        self.xnnpackDelegate = xnnpackDelegate
        self.api = api
        self.embeddingDimension = embeddingDimension
        ownsInterpreter = false
        ownsDelegate = false
    }

    deinit {
        api.interpreterDelete(pointer)
        REPACKDeleteXNNPackDelegate(xnnpackDelegate)
    }

    func invoke(_ inputIDs: [Int32]) throws -> [Float] {
        guard let input = api.inputTensor(pointer, 0) else {
            throw SemanticScoringError.runtimeFailure
        }
        let inputStatus = inputIDs.withUnsafeBytes {
            api.tensorCopyFromBuffer(input, $0.baseAddress, $0.count)
        }
        guard inputStatus == liteRTOk,
              api.invoke(pointer) == liteRTOk,
              let output = api.outputTensor(pointer, 0) else {
            throw SemanticScoringError.runtimeFailure
        }

        let expectedBytes = embeddingDimension * MemoryLayout<Float>.stride
        guard api.tensorByteSize(output) == expectedBytes else {
            throw SemanticScoringError.invalidEmbeddingDimension
        }
        var values = [Float](repeating: 0, count: embeddingDimension)
        let outputStatus = values.withUnsafeMutableBytes {
            api.tensorCopyToBuffer(output, $0.baseAddress, $0.count)
        }
        guard outputStatus == liteRTOk else {
            throw SemanticScoringError.runtimeFailure
        }
        return values
    }

    private static func validateSignature(
        interpreter: OpaquePointer,
        api: LiteRTAPI,
        sequenceLength: Int,
        embeddingDimension: Int
    ) throws {
        let inputCount = api.inputTensorCount(interpreter)
        let outputCount = api.outputTensorCount(interpreter)
        guard inputCount == 1, outputCount == 1 else {
            throw SemanticScoringError.invalidModelSignature(
                "expected 1 input and 1 output; found \(inputCount) and \(outputCount)"
            )
        }
        guard let input = api.inputTensor(interpreter, 0),
              api.tensorType(input) == liteRTInt32,
              tensorShape(input, api: api) == [1, sequenceLength] else {
            throw SemanticScoringError.invalidModelSignature(
                "input is not Int32[1, \(sequenceLength)]"
            )
        }
        guard let output = api.outputTensor(interpreter, 0),
              api.tensorType(output) == liteRTFloat32,
              tensorShape(output, api: api).last == embeddingDimension else {
            throw SemanticScoringError.invalidModelSignature(
                "output is not Float32[..., \(embeddingDimension)]"
            )
        }
    }

    private static func tensorShape(
        _ tensor: OpaquePointer,
        api: LiteRTAPI
    ) -> [Int] {
        let count = api.tensorNumDims(tensor)
        guard count >= 0 else { return [] }
        return (0..<count).map { Int(api.tensorDim(tensor, $0)) }
    }
}

private nonisolated final class LiteRTAPI: @unchecked Sendable {
    typealias ModelCreateFromFile = @convention(c) (
        UnsafePointer<CChar>?
    ) -> OpaquePointer?
    typealias ModelDelete = @convention(c) (OpaquePointer?) -> Void
    typealias OptionsCreate = @convention(c) () -> OpaquePointer?
    typealias OptionsDelete = @convention(c) (OpaquePointer?) -> Void
    typealias OptionsSetNumThreads = @convention(c) (
        OpaquePointer?,
        Int32
    ) -> Void
    typealias InterpreterCreate = @convention(c) (
        OpaquePointer?,
        OpaquePointer?
    ) -> OpaquePointer?
    typealias InterpreterDelete = @convention(c) (OpaquePointer?) -> Void
    typealias AllocateTensors = @convention(c) (
        OpaquePointer?
    ) -> LiteRTStatus
    typealias TensorCount = @convention(c) (OpaquePointer?) -> Int32
    typealias InputTensor = @convention(c) (
        OpaquePointer?,
        Int32
    ) -> OpaquePointer?
    typealias OutputTensor = @convention(c) (
        OpaquePointer?,
        Int32
    ) -> OpaquePointer?
    typealias Invoke = @convention(c) (OpaquePointer?) -> LiteRTStatus
    typealias TensorType = @convention(c) (
        OpaquePointer?
    ) -> LiteRTType
    typealias TensorNumDims = @convention(c) (
        OpaquePointer?
    ) -> Int32
    typealias TensorDim = @convention(c) (
        OpaquePointer?,
        Int32
    ) -> Int32
    typealias TensorByteSize = @convention(c) (
        OpaquePointer?
    ) -> Int
    typealias TensorCopyFromBuffer = @convention(c) (
        OpaquePointer?,
        UnsafeRawPointer?,
        Int
    ) -> LiteRTStatus
    typealias TensorCopyToBuffer = @convention(c) (
        OpaquePointer?,
        UnsafeMutableRawPointer?,
        Int
    ) -> LiteRTStatus

    let modelCreateFromFile: ModelCreateFromFile
    let modelDelete: ModelDelete
    let optionsCreate: OptionsCreate
    let optionsDelete: OptionsDelete
    let optionsSetNumThreads: OptionsSetNumThreads
    let interpreterCreate: InterpreterCreate
    let interpreterDelete: InterpreterDelete
    let allocateTensors: AllocateTensors
    let inputTensorCount: TensorCount
    let outputTensorCount: TensorCount
    let inputTensor: InputTensor
    let outputTensor: OutputTensor
    let invoke: Invoke
    let tensorType: TensorType
    let tensorNumDims: TensorNumDims
    let tensorDim: TensorDim
    let tensorByteSize: TensorByteSize
    let tensorCopyFromBuffer: TensorCopyFromBuffer
    let tensorCopyToBuffer: TensorCopyToBuffer

    private let imageHandle: UnsafeMutableRawPointer

    init() throws {
        let imageHandle = try Self.embeddingRuntimeImage()
        do {
            modelCreateFromFile = try Self.symbol("TfLiteModelCreateFromFile", in: imageHandle)
            modelDelete = try Self.symbol("TfLiteModelDelete", in: imageHandle)
            optionsCreate = try Self.symbol("TfLiteInterpreterOptionsCreate", in: imageHandle)
            optionsDelete = try Self.symbol("TfLiteInterpreterOptionsDelete", in: imageHandle)
            optionsSetNumThreads = try Self.symbol(
                "TfLiteInterpreterOptionsSetNumThreads",
                in: imageHandle
            )
            interpreterCreate = try Self.symbol("TfLiteInterpreterCreate", in: imageHandle)
            interpreterDelete = try Self.symbol("TfLiteInterpreterDelete", in: imageHandle)
            allocateTensors = try Self.symbol(
                "TfLiteInterpreterAllocateTensors",
                in: imageHandle
            )
            inputTensorCount = try Self.symbol(
                "TfLiteInterpreterGetInputTensorCount",
                in: imageHandle
            )
            outputTensorCount = try Self.symbol(
                "TfLiteInterpreterGetOutputTensorCount",
                in: imageHandle
            )
            inputTensor = try Self.symbol("TfLiteInterpreterGetInputTensor", in: imageHandle)
            outputTensor = try Self.symbol("TfLiteInterpreterGetOutputTensor", in: imageHandle)
            invoke = try Self.symbol("TfLiteInterpreterInvoke", in: imageHandle)
            tensorType = try Self.symbol("TfLiteTensorType", in: imageHandle)
            tensorNumDims = try Self.symbol("TfLiteTensorNumDims", in: imageHandle)
            tensorDim = try Self.symbol("TfLiteTensorDim", in: imageHandle)
            tensorByteSize = try Self.symbol("TfLiteTensorByteSize", in: imageHandle)
            tensorCopyFromBuffer = try Self.symbol(
                "TfLiteTensorCopyFromBuffer",
                in: imageHandle
            )
            tensorCopyToBuffer = try Self.symbol(
                "TfLiteTensorCopyToBuffer",
                in: imageHandle
            )
        } catch {
            dlclose(imageHandle)
            throw error
        }
        self.imageHandle = imageHandle
    }

    deinit {
        dlclose(imageHandle)
    }

    private static func embeddingRuntimeImage() throws
        -> UnsafeMutableRawPointer {
        guard let frameworkURL = Bundle.main.privateFrameworksURL?
            .appending(path: "CLiteRTLM.framework/CLiteRTLM") else {
            throw LiteRTAPIError.embeddingImageNotFound
        }
        let flags = RTLD_NOW | RTLD_LOCAL | RTLD_FIRST
        guard let handle = dlopen(
            frameworkURL.path(percentEncoded: false),
            flags
        ) else {
            throw LiteRTAPIError.embeddingImageNotFound
        }
        return handle
    }

    private static func symbol<T>(
        _ name: String,
        in handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw LiteRTAPIError.missingSymbol(name)
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private nonisolated enum LiteRTAPIError: Error {
    case embeddingImageNotFound
    case missingSymbol(String)
}
