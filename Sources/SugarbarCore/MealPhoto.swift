import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Phone photos are 12 MP; Claude only needs enough pixels to recognise the plate.
/// Takes any format ImageIO reads (JPEG, HEIC, PNG, TIFF), applies its EXIF orientation, never upscales.
public func mealPhotoJPEG(from imageData: Data, maxDimension: Int = 1280, quality: Double = 0.75) -> Data? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, max(width, height)),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
