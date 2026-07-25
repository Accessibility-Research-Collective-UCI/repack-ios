import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

actor ImageStore {
    enum StoreError: LocalizedError {
        case invalidImage
        case unableToCreateImage
        case unableToEncodeImage
        case unmanagedURL

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                String(localized: "The selected file is not a supported image.")
            case .unableToCreateImage:
                String(localized: "The image could not be prepared.")
            case .unableToEncodeImage:
                String(localized: "The prepared image could not be saved.")
            case .unmanagedURL:
                String(localized: "The image is outside the app's managed image directory.")
            }
        }
    }

    static let shared = ImageStore()

    static let maximumImageArea = 2_600_000
    static let maximumImageDimension = 4_096
    static let previewMaximumDimension = 720

    private let customDirectoryURL: URL?
    private let fileManager: FileManager
    private let previewCache = NSCache<NSURL, UIImage>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        customDirectoryURL = directoryURL
        self.fileManager = fileManager
        previewCache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func store(data: Data) throws -> URL {
        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw StoreError.invalidImage
        }

        let image = try downsampledImage(from: source)
        try Task.checkCancellation()
        return try persist(image)
    }

    func store(image: UIImage) throws -> URL {
        try Task.checkCancellation()

        let sourceImage: CIImage
        if let cgImage = image.cgImage {
            sourceImage = CIImage(cgImage: cgImage)
                .oriented(image.imageOrientation.cgImagePropertyOrientation)
        } else if let ciImage = image.ciImage {
            sourceImage = ciImage.oriented(image.imageOrientation.cgImagePropertyOrientation)
        } else {
            throw StoreError.invalidImage
        }

        let extent = sourceImage.extent.integral
        guard extent.width > 0, extent.height > 0 else {
            throw StoreError.invalidImage
        }

        let scale = Self.scale(
            width: Int(extent.width),
            height: Int(extent.height)
        )
        let preparedImage = scale < 1
            ? sourceImage.transformed(by: .init(scaleX: scale, y: scale))
            : sourceImage

        guard let cgImage = ciContext.createCGImage(preparedImage, from: preparedImage.extent) else {
            throw StoreError.unableToCreateImage
        }

        try Task.checkCancellation()
        return try persist(cgImage)
    }

    func preview(at url: URL) throws -> UIImage {
        try validateManagedURL(url)

        let cacheKey = url.standardizedFileURL as NSURL
        if let cachedImage = previewCache.object(forKey: cacheKey) {
            return cachedImage
        }

        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw StoreError.invalidImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.previewMaximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw StoreError.unableToCreateImage
        }

        try Task.checkCancellation()
        let image = UIImage(cgImage: thumbnail)
        previewCache.setObject(
            image,
            forKey: cacheKey,
            cost: thumbnail.width * thumbnail.height * 4
        )
        return image
    }

    func remove(_ url: URL) throws {
        try validateManagedURL(url)
        previewCache.removeObject(forKey: url.standardizedFileURL as NSURL)

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func remove(_ urls: some Sequence<URL>) {
        for url in urls {
            try? remove(url)
        }
    }

    func removeOrphans(keeping retainedURLs: Set<URL>) throws {
        let directory = try imagesDirectory()
        let retainedPaths = Set(retainedURLs.map(\.standardizedFileURL.path))
        let storedURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        for url in storedURLs where !retainedPaths.contains(url.standardizedFileURL.path) {
            try remove(url)
        }
    }

    private func downsampledImage(from source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let width = Self.pixelValue(properties[kCGImagePropertyPixelWidth]),
            let height = Self.pixelValue(properties[kCGImagePropertyPixelHeight]),
            width > 0,
            height > 0
        else {
            throw StoreError.invalidImage
        }

        let scale = Self.scale(width: width, height: height)
        let maximumDimension = max(
            1,
            Int((Double(max(width, height)) * scale).rounded(.down))
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw StoreError.unableToCreateImage
        }
        return image
    }

    private func persist(_ sourceImage: CGImage) throws -> URL {
        let image = try opaqueSRGBImage(from: sourceImage)
        let encodedData = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw StoreError.unableToEncodeImage
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw StoreError.unableToEncodeImage
        }

        let directory = try imagesDirectory()
        let destinationURL = directory.appending(path: "image-\(UUID().uuidString).jpg")
        try (encodedData as Data).write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private func opaqueSRGBImage(from sourceImage: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: sourceImage.width,
                  height: sourceImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw StoreError.unableToCreateImage
        }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(
            CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        )
        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        )

        guard let image = context.makeImage() else {
            throw StoreError.unableToCreateImage
        }
        return image
    }

    private func imagesDirectory() throws -> URL {
        let directory = if let customDirectoryURL {
            customDirectoryURL
        } else {
            try ModelManager.applicationSupportDirectory()
                .appending(path: "Images", directoryHint: .isDirectory)
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func validateManagedURL(_ url: URL) throws {
        let directoryPath = try imagesDirectory()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path

        guard filePath.hasPrefix(directoryPath + "/") else {
            throw StoreError.unmanagedURL
        }
    }

    private static func scale(width: Int, height: Int) -> CGFloat {
        let areaScale = sqrt(
            Double(maximumImageArea) / (Double(width) * Double(height))
        )
        let dimensionScale = Double(maximumImageDimension) / Double(max(width, height))
        return CGFloat(min(1, areaScale, dimensionScale))
    }

    private static func pixelValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}

private extension UIImage.Orientation {
    nonisolated var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up:
            .up
        case .upMirrored:
            .upMirrored
        case .down:
            .down
        case .downMirrored:
            .downMirrored
        case .left:
            .left
        case .leftMirrored:
            .leftMirrored
        case .right:
            .right
        case .rightMirrored:
            .rightMirrored
        @unknown default:
            .up
        }
    }
}
