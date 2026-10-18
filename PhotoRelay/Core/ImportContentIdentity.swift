import CryptoKit
import Foundation

public enum ImportIdentityError: LocalizedError {
    case invalidHash
    case changedFile
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidHash: return "文件内容校验值无效。"
        case .changedFile: return "文件内容在核对时发生变化，请重新选择来源。"
        case .unavailable(let text): return "无法核对文件内容：\(text)"
        }
    }
}

/// Identity describes bytes and resource roles, never filenames, UUIDs or ZIP CRC32.
public enum ImportContentIdentity {
    public static func media(kind: MediaKind, primarySHA256: String, pairedSHA256: String? = nil) throws -> String {
        let primary = try normalized(primarySHA256)
        let paired = try pairedSHA256.map(normalized)
        return "media-v1:\(kind.rawValue):\(primary):\(paired ?? "-")"
    }

    public static func source(kind: SourceKind, sha256: String) throws -> String {
        "source-v1:\(kind.rawValue):\(try normalized(sha256))"
    }

    /// Call only after prepareMedia has validated these manifest hashes, or for
    /// a durable .saved checkpoint produced by that validated older importer.
    public static func verifiedManifest(_ item: ImportItem) throws -> String? {
        guard let primary = item.expectedSHA256 else { return nil }
        if let paired = item.pairedVideo {
            guard let video = paired.sha256 else { return nil }
            return try media(kind: item.kind, primarySHA256: primary, pairedSHA256: video)
        }
        return try media(kind: item.kind, primarySHA256: primary)
    }

    private static func normalized(_ value: String) throws -> String {
        let value = value.lowercased()
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ImportIdentityError.invalidHash
        }
        return value
    }
}

/// Streams full hashes on an actor executor. A 30 GB source never becomes Data
/// in memory; canceled verification does not produce an identity.
public actor ImportContentHasher {
    public init() {}

    public func hashFile(_ url: URL, expectedBytes: UInt64,
                         expectedModifiedAt: Date? = nil) throws -> String {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<String, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { local in
            result = Result {
                var fresh = local
                fresh.removeAllCachedResourceValues()
                let before = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard before.isRegularFile == true, before.isSymbolicLink != true,
                      before.fileSize.map({ UInt64(max(0, $0)) }) == expectedBytes,
                      expectedModifiedAt == nil || before.contentModificationDate == expectedModifiedAt else {
                    throw ImportIdentityError.changedFile
                }
                let input = try FileHandle(forReadingFrom: local)
                defer { try? input.close() }
                var hash = SHA256()
                var count: UInt64 = 0
                while true {
                    let readChunk = try autoreleasepool { () throws -> Bool in
                        try Task.checkCancellation()
                        guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
                        let next = count.addingReportingOverflow(UInt64(chunk.count))
                        guard !next.overflow, next.partialValue <= expectedBytes else { throw ImportIdentityError.changedFile }
                        count = next.partialValue
                        hash.update(data: chunk)
                        return true
                    }
                    if !readChunk { break }
                }
                fresh.removeAllCachedResourceValues()
                let after = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard count == expectedBytes, after.fileSize == before.fileSize,
                      after.contentModificationDate == before.contentModificationDate else { throw ImportIdentityError.changedFile }
                try Task.checkCancellation()
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        if let coordinationError { throw ImportIdentityError.unavailable(coordinationError.localizedDescription) }
        guard let result else { throw ImportIdentityError.unavailable("文件提供方未返回内容。") }
        return try result.get()
    }

    /// A folder has no immutable container digest. Before retaining old saved
    /// states during relink, verify each known resource directly on the selected
    /// volume. Never infer a saved identity from name/size/date alone.
    public func verifyFolderHistory(_ items: [ImportItem], root: URL) throws {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        for item in items {
            try Task.checkCancellation()
            let expected = try item.contentIdentity ?? ImportContentIdentity.verifiedManifest(item)
            guard let expected else {
                if item.state == .saved || item.state == .uncertain || item.state == .inFlight {
                    throw ImportIdentityError.unavailable("旧任务没有可验证的内容记录，无法安全关联这个文件夹。请先核对旧任务与相册。")
                }
                continue
            }
            let primary = try hashFolderResource(path: item.relativePath, bytes: item.byteCount,
                                                  modifiedAt: item.modifiedAt, root: root)
            let paired = try item.pairedVideo.map {
                try hashFolderResource(path: $0.relativePath, bytes: $0.byteCount,
                                       modifiedAt: $0.modifiedAt, root: root)
            }
            guard try ImportContentIdentity.media(kind: item.kind, primarySHA256: primary,
                                                  pairedSHA256: paired) == expected else {
                throw ImportIdentityError.changedFile
            }
        }
    }

    private func hashFolderResource(path: String, bytes: UInt64, modifiedAt: Date?, root: URL) throws -> String {
        guard MediaPolicy.isSafeRelativePath(path) else { throw ImportIdentityError.changedFile }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        coordinator.coordinate(readingItemAt: root, options: [], error: &coordinationError) { localRoot in
            result = Result {
                let rootValues = try localRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                    throw ImportIdentityError.changedFile
                }
                var child = localRoot
                let components = path.split(separator: "/")
                for (index, component) in components.enumerated() {
                    child.appendPathComponent(String(component))
                    child.removeAllCachedResourceValues()
                    let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    guard values.isSymbolicLink != true,
                          index == components.count - 1 || values.isDirectory == true else {
                        throw ImportIdentityError.changedFile
                    }
                }
                return child
            }
        }
        if let coordinationError { throw ImportIdentityError.unavailable(coordinationError.localizedDescription) }
        guard let result else { throw ImportIdentityError.changedFile }
        // Coordinate the individual file as well, so a file provider may hydrate
        // it while the selected folder's security scope remains open.
        return try hashFile(result.get(), expectedBytes: bytes, expectedModifiedAt: modifiedAt)
    }

    public func preparedIdentity(item: ImportItem, fileURL: URL, pairedVideoURL: URL?) async throws -> String {
        // prepareMedia has already fully checked the manifest resource SHA256s.
        if let verified = try ImportContentIdentity.verifiedManifest(item) { return verified }
        let main = try hashFile(fileURL, expectedBytes: item.byteCount)
        var video: String?
        if let paired = item.pairedVideo {
            guard let pairedVideoURL else { throw ImportIdentityError.changedFile }
            video = try hashFile(pairedVideoURL, expectedBytes: paired.byteCount)
        }
        return try ImportContentIdentity.media(kind: item.kind, primarySHA256: main, pairedSHA256: video)
    }
}
