import Foundation
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
private extension UIImage {
    func resizedDown(to targetSize: CGSize) -> UIImage? {
        let maxW = max(1, Int(targetSize.width))
        let maxH = max(1, Int(targetSize.height))
        // If already smaller than target, skip expensive work
        if size.width <= CGFloat(maxW) && size.height <= CGFloat(maxH) { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maxW, height: maxH), format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(x: 0, y: 0, width: CGFloat(maxW), height: CGFloat(maxH)))
        }
    }
}
#endif

internal enum AttachmentImageNormalizer {
    static let maxLongEdgePixels = 1600
    static let suspiciousFileSizeBytes = 20 * 1024 * 1024
    private static let jpegCompressionQuality: CGFloat = 0.9

    struct Result {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let originalPixelWidth: Int?
        let originalPixelHeight: Int?
        let wasClamped: Bool
        let suspiciouslyLargeSource: Bool
    }

    static func normalizeAttachmentData(_ data: Data, maxLongEdgePixels: Int = AttachmentImageNormalizer.maxLongEdgePixels) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return normalize(source: source, fileBytes: data.count, maxLongEdgePixels: maxLongEdgePixels)
    }

    static func normalizeAttachmentImage(_ image: UIImage, maxLongEdgePixels: Int = AttachmentImageNormalizer.maxLongEdgePixels) -> Result? {
        // This JPEG is only a transient handed to the (downsampling) CGImageSource
        // normalizer, so encoding at lossless 1.0 just balloons peak memory on large
        // photos for no quality gain — the result is downscaled to maxLongEdgePixels.
        if let data = image.jpegData(compressionQuality: jpegCompressionQuality),
           let normalized = normalizeAttachmentData(data, maxLongEdgePixels: maxLongEdgePixels) {
            return normalized
        }

        let fallbackWidth = max(1, Int(image.size.width.rounded()))
        let fallbackHeight = max(1, Int(image.size.height.rounded()))
        let longestEdge = max(fallbackWidth, fallbackHeight)
        let outputImage: UIImage
        if longestEdge > maxLongEdgePixels {
            let scale = CGFloat(maxLongEdgePixels) / CGFloat(longestEdge)
            let targetSize = CGSize(
                width: max(1, floor(CGFloat(fallbackWidth) * scale)),
                height: max(1, floor(CGFloat(fallbackHeight) * scale))
            )
            outputImage = image.resizedDown(to: targetSize) ?? image
        } else {
            outputImage = image
        }
        guard let jpeg = outputImage.jpegData(compressionQuality: jpegCompressionQuality) else { return nil }
        let outputWidth = max(1, Int(outputImage.size.width.rounded()))
        let outputHeight = max(1, Int(outputImage.size.height.rounded()))
        return Result(
            data: jpeg,
            pixelWidth: outputWidth,
            pixelHeight: outputHeight,
            originalPixelWidth: fallbackWidth,
            originalPixelHeight: fallbackHeight,
            wasClamped: outputWidth != fallbackWidth || outputHeight != fallbackHeight,
            suspiciouslyLargeSource: false
        )
    }

    static func metadata(forFileAt url: URL) -> (pixelWidth: Int, pixelHeight: Int, fileBytes: Int?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let width = intValue(properties[kCGImagePropertyPixelWidth]) ?? 0
        let height = intValue(properties[kCGImagePropertyPixelHeight]) ?? 0
        let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return (width, height, fileBytes)
    }

    private static func normalize(source: CGImageSource, fileBytes: Int?, maxLongEdgePixels: Int) -> Result? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalPixelWidth = intValue(properties?[kCGImagePropertyPixelWidth])
        let originalPixelHeight = intValue(properties?[kCGImagePropertyPixelHeight])
        let longEdge = max(originalPixelWidth ?? 0, originalPixelHeight ?? 0)
        let suspiciouslyLargeSource = (fileBytes ?? 0) > suspiciousFileSizeBytes
        let outputMaxPixel = max(1, min(maxLongEdgePixels, longEdge > 0 ? longEdge : maxLongEdgePixels))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputMaxPixel,
            kCGImageSourceShouldCache: false
        ]
        guard let transformedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpegData = encodeJPEG(from: transformedImage) else {
            return nil
        }

        let outputPixelWidth = transformedImage.width
        let outputPixelHeight = transformedImage.height
        let wasClamped = {
            guard let originalPixelWidth, let originalPixelHeight else { return false }
            return outputPixelWidth != originalPixelWidth || outputPixelHeight != originalPixelHeight
        }()

        return Result(
            data: jpegData,
            pixelWidth: outputPixelWidth,
            pixelHeight: outputPixelHeight,
            originalPixelWidth: originalPixelWidth,
            originalPixelHeight: originalPixelHeight,
            wasClamped: wasClamped,
            suspiciouslyLargeSource: suspiciouslyLargeSource
        )
    }

    private static func encodeJPEG(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let int as Int:
            return int
        default:
            return nil
        }
    }
}
