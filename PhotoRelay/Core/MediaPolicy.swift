import Foundation

public enum MediaPolicy {
    public static func kind(for path: String) -> MediaKind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "dng": return .photo
        case "mov", "mp4", "m4v": return .video
        default: return nil
        }
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\0") else { return false }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              !(parts.first?.contains(":") ?? false) else { return false }
        return true
    }

    public static func shouldIgnore(_ path: String) -> Bool {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains {
            $0 == "__MACOSX" || $0.hasPrefix(".")
        }
    }
}
