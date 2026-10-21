import Foundation

public enum PackageImportError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return "照片包清单无法核对：\(reason)" }
    }
}

/// A Dropack manifest is data, never authority to reference files outside this package.
public enum PackageImportResolver {
    public static func resolve(_ manifest: PhotoPackageManifest, scanned: [ImportItem]) throws -> [ImportItem] {
        try manifest.validate()
        let byPath = Dictionary(grouping: scanned, by: \.relativePath)
        var used = Set<String>()
        var result: [ImportItem] = []
        func resource(_ path: String, kind: MediaKind) throws -> ImportItem {
            guard let matches = byPath[path], matches.count == 1, let item = matches.first,
                  item.kind == kind, used.insert(path).inserted else {
                throw PackageImportError.invalid("资源缺失、类型不匹配或重复：\(path)")
            }
            return item
        }
        for entry in manifest.items {
            let primaryPath = entry.photoPath ?? entry.videoPath
            guard let primaryPath else { throw PackageImportError.invalid("项目缺少资源。") }
            var item = try resource(primaryPath, kind: entry.photoPath == nil ? .video : .photo)
            item.id = "dropack:\(entry.id)"
            item.creationDate = entry.creationDate
            item.expectedSHA256 = entry.photoPath == nil ? entry.videoSHA256 : entry.photoSHA256
            if let previewPath = entry.previewPath {
                let preview = try resource(previewPath, kind: .photo)
                guard preview.byteCount <= 1024 * 1024 else { throw PackageImportError.invalid("预览图超过大小限制。") }
                item.previewPath = previewPath
            }
            if entry.isLivePhoto {
                guard let videoPath = entry.videoPath else { throw PackageImportError.invalid("实况照片缺少视频。") }
                var video = try resource(videoPath, kind: .video)
                video.expectedSHA256 = entry.videoSHA256
                item.pairedVideo = ImportResource(item: video)
            }
            result.append(item)
        }
        guard used.count == scanned.count else {
            throw PackageImportError.invalid("ZIP 中有未列入清单的媒体，不能把它当成完整照片包。")
        }
        return result
    }
}
