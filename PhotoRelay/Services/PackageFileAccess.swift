import CryptoKit
import Foundation

/// File-provider access for outgoing albums. It never writes the source or imports
/// it into Photos; ZIP appends read bounded chunks while a coordinated read is held.
enum PackageFileAccess {
    static func scan(_ urls: [URL]) async throws -> [PackageAsset] {
        var output: [PackageAsset] = []
        var seen = Set<String>()
        for root in urls {
            try Task.checkCancellation()
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let isFolder = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let files: [URL] = try coordinate(root) { coordinated in
                if !isFolder { return [coordinated] }
                var failure: Error?
                guard let enumerator = FileManager.default.enumerator(at: coordinated,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
                    throw MediaSourceError.sourceUnavailable("")
                }
                var result: [URL] = []
                var visited = 0
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    visited += 1
                    guard visited <= PackageFormatLimits.maxZIPEntries * 2 else { throw PackageLimitError.selectionTooLarge }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if values.isRegularFile == true, MediaPolicy.kind(for: file.lastPathComponent) != nil { result.append(file) }
                }
                if let failure { throw failure }
                return result
            }
            for file in files {
                try Task.checkCancellation()
                let canonical = file.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                let prefix = root.standardizedFileURL.path + "/"
                let relative = isFolder ? String(canonical.dropFirst(prefix.count)) : file.lastPathComponent
                guard (!isFolder || canonical.hasPrefix(prefix)), MediaPolicy.isSafeRelativePath(relative),
                      !MediaPolicy.shouldIgnore(relative), let kind = MediaPolicy.kind(for: relative) else { continue }
                let values = try coordinate(file) { try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0 else { throw PhotoPackageError.emptyResource(file.lastPathComponent) }
                var item = PackageAsset(assetIdentifier: "file:" + UUID().uuidString)
                item.title = file.lastPathComponent; item.kind = kind
                item.captureDate = await MediaCaptureDate.read(file, kind: kind) ?? values.creationDate ?? values.contentModificationDate
                item.sourceModifiedAt = values.contentModificationDate
                item.fileSource = PackageFileSource(bookmark: bookmark, relativePath: relative, isFolder: isFolder,
                    byteCount: UInt64(size), modifiedAt: values.contentModificationDate)
                output.append(item)
                try PackageFormatLimits.validateSelectionCount(output.count)
            }
        }
        guard !output.isEmpty else { throw PhotoPackageError.unsupported("所选文件") }
        return output.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
    }

    static func resolve(_ source: PackageFileSource) throws -> (root: URL, file: URL) {
        var stale = false
        let root = try URL(resolvingBookmarkData: source.bookmark, options: .withoutUI,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw MediaSourceError.sourceUnavailable("请重新选择原文件。") }
        let file = source.isFolder ? root.appendingPathComponent(source.relativePath) : root
        guard MediaPolicy.isSafeRelativePath(source.relativePath),
              !source.isFolder || file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw PackageModelError.invalidCheckpoint
        }
        if source.isFolder {
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw PackageModelError.invalidCheckpoint
            }
        }
        return (root, file)
    }

    static func validate(_ url: URL, source: PackageFileSource) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              UInt64(max(0, values.fileSize ?? 0)) == source.byteCount,
              values.contentModificationDate == source.modifiedAt else { throw MediaSourceError.itemChanged(source.relativePath) }
    }

    static func hash(_ url: URL, byteCount: UInt64,
                     progress: @Sendable (Double) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var readBytes: UInt64 = 0
        var lastUpdate = -Double.infinity
        while true {
            // FileHandle's Objective-C backing may autorelease each NSData.
            // Detached tasks do not drain that pool between Swift loop turns.
            let readChunk = try autoreleasepool { () throws -> Bool in
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                let next = readBytes.addingReportingOverflow(UInt64(data.count))
                guard !next.overflow, next.partialValue <= byteCount else { throw PhotoPackageError.archiveMismatch }
                hasher.update(data: data)
                readBytes = next.partialValue
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.1 {
                    lastUpdate = now
                    progress(min(1, Double(readBytes) / Double(max(1, byteCount))))
                }
                return true
            }
            if !readChunk { break }
        }
        guard readBytes == byteCount else { throw PhotoPackageError.archiveMismatch }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func coordinate<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { local in
            result = Result { try body(local) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw MediaSourceError.sourceUnavailable("") }
        return try result.get()
    }

}
