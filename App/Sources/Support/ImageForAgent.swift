import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image made ready for an agent: screenshots stay PNG; photos (HEIC and
/// others) become JPEG; anything over 2048 px on a side is scaled down
/// (ImageIO thumbnails: no full decode, orientation applied), so it stays
/// well under `terminal.put`'s 8 MB. Safe off the main thread.
struct ImageForAgent: Sendable {
    var data: Data
    var name: String

    static let maxSide = 2048

    init?(_ original: Data) {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let isPNG = CGImageSourceGetType(source).map { UTType($0 as String) == .png } ?? false
        let stamp = Self.stamp()
        // Already right: a PNG screenshot of a sane size goes as it is.
        if isPNG, original.count <= 6_000_000, max(width, height) <= Self.maxSide {
            data = original
            name = "image-\(stamp).png"
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if isPNG, let png = Self.encode(image, as: .png, quality: nil), png.count <= 6_000_000 {
            data = png
            name = "image-\(stamp).png"
        } else if let jpeg = Self.encode(image, as: .jpeg, quality: 0.85) {
            data = jpeg
            name = "photo-\(stamp).jpg"
        } else {
            return nil
        }
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// `20261111-165257`, in ASCII digits and the Gregorian calendar whatever the device's settings.
    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
