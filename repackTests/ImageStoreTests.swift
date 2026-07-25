import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import repack

@Suite("Image Store", .serialized)
struct ImageStoreTests {
    @Test("Large images are oriented, bounded, and stripped of private metadata")
    func preparesLargeImage() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDirectory() }

        let data = try makeJPEG(
            width: 2_400,
            height: 1_600,
            orientation: .right,
            includesGPS: true
        )
        let url = try await fixture.store.store(data: data)
        let properties = try imageProperties(at: url)
        let width = try #require(pixelValue(properties[kCGImagePropertyPixelWidth]))
        let height = try #require(pixelValue(properties[kCGImagePropertyPixelHeight]))

        #expect(width * height <= ImageStore.maximumImageArea)
        #expect(height > width)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(
            pixelValue(properties[kCGImagePropertyOrientation]) == nil
                || pixelValue(properties[kCGImagePropertyOrientation]) == 1
        )
    }

    @Test("Camera images are normalized off the main actor")
    func preparesCameraImage() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDirectory() }
        let encodedImage = try makeJPEG(width: 1_600, height: 1_000)
        let decodedImage = try #require(UIImage(data: encodedImage))
        let cgImage = try #require(decodedImage.cgImage)
        let cameraImage = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        let url = try await fixture.store.store(image: cameraImage)
        let properties = try imageProperties(at: url)
        let width = try #require(pixelValue(properties[kCGImagePropertyPixelWidth]))
        let height = try #require(pixelValue(properties[kCGImagePropertyPixelHeight]))

        #expect(height > width)
        #expect(width * height <= ImageStore.maximumImageArea)
    }

    @Test("Small images are not upscaled")
    func preservesSmallImageDimensions() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDirectory() }

        let url = try await fixture.store.store(
            data: makeJPEG(width: 400, height: 300)
        )
        let properties = try imageProperties(at: url)

        #expect(pixelValue(properties[kCGImagePropertyPixelWidth]) == 400)
        #expect(pixelValue(properties[kCGImagePropertyPixelHeight]) == 300)
    }

    @Test("Previews are cached and orphan cleanup preserves retained images")
    func cachesPreviewsAndRemovesOrphans() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDirectory() }

        let retainedURL = try await fixture.store.store(
            data: makeJPEG(width: 800, height: 600)
        )
        let orphanURL = try await fixture.store.store(
            data: makeJPEG(width: 640, height: 480)
        )
        let firstPreview = try await fixture.store.preview(at: retainedURL)
        let secondPreview = try await fixture.store.preview(at: retainedURL)

        #expect(firstPreview === secondPreview)

        try await fixture.store.removeOrphans(keeping: [retainedURL])

        #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))

        try await fixture.store.remove(retainedURL)
        #expect(!FileManager.default.fileExists(atPath: retainedURL.path))
    }

    @Test("Replacing, failing, resetting, and launching manage image ownership")
    @MainActor
    func modelImageLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDirectory() }
        let model = REPACKViewModel(imageStore: fixture.store)
        let firstData = try makeJPEG(width: 800, height: 600)
        let secondData = try makeJPEG(width: 600, height: 800)

        await model.attachImage(data: firstData)
        let firstURL = try #require(model.selectedImageURL)

        await model.attachImage(data: Data("not an image".utf8))
        #expect(model.selectedImageURL == firstURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))

        await model.attachImage(data: secondData)
        let secondURL = try #require(model.selectedImageURL)
        #expect(secondURL != firstURL)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))

        await model.resetRun()
        #expect(model.selectedImageURL == nil)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))

        let orphanURL = try await fixture.store.store(data: firstData)
        await model.prepareForLaunch()
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    private struct Fixture {
        let directoryURL: URL
        let store: ImageStore

        init() throws {
            directoryURL = FileManager.default.temporaryDirectory
                .appending(path: "ImageStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            store = ImageStore(directoryURL: directoryURL)
        }

        func removeDirectory() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private func makeJPEG(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation = .up,
        includesGPS: Bool = false
    ) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let encodedData = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                encodedData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )

        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        if includesGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 33.6405,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 117.8443,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: "private source metadata"
            ]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return encodedData as Data
    }

    private func imageProperties(at url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }

    private func pixelValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}
