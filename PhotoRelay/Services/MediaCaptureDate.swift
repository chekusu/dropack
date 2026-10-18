import AVFoundation
import Foundation
import ImageIO

enum MediaCaptureDate {
    /// Metadata-only reads; decoding an original into memory is never needed.
    static func read(_ url: URL, kind: MediaKind) async -> Date? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if kind == .photo {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return formatter.date(from: text)
        }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.creationDate) else { return nil }
        return try? await metadata.load(.dateValue)
    }
}
