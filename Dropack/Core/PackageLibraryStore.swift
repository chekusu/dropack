import Foundation

/// Each UUID directory owns its checkpoint, immutable archive, alternate export,
/// staging files and thumbnails. The active pointer never owns package lifetime.
public struct PackageLibraryStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    private struct Selection: Codable { var id: UUID? }
    private var selectionURL: URL { root.appendingPathComponent("active-package.json") }
    private var legacyURL: URL { root.appendingPathComponent("package.json") }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Old versions already placed payloads inside their UUID directory. Write
        // the per-package journal and pointer before removing the legacy journal;
        // no payload move/copy and an interrupted migration is safe to repeat.
        let legacy: PackageJob?
        do { legacy = try PackageRecovery.load(from: legacyURL) }
        catch {
            try isolateDamagedLegacyRecord()
            return
        }
        if let legacy {
            let destination = try checkpointURL(id: legacy.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard let existing = try PackageRecovery.load(from: destination), existing.id == legacy.id else {
                    throw PackageModelError.invalidCheckpoint
                }
            } else { try PackageRecovery.save(legacy, to: destination) }
            if !FileManager.default.fileExists(atPath: selectionURL.path) { try select(legacy.id) }
            try FileManager.default.removeItem(at: legacyURL)
        }
    }

    public func directory(id: UUID) throws -> URL {
        let result = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: result.path) {
            let values = try result.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PackageModelError.invalidCheckpoint
            }
        }
        return result
    }

    public func checkpointURL(id: UUID) throws -> URL {
        let result = try directory(id: id).appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: result.path) {
            _ = try PackageRecovery.fileSize(result) // Reject a journal symlink.
        }
        return result
    }

    public func load(id: UUID) throws -> PackageJob? {
        guard let job = try PackageRecovery.load(from: checkpointURL(id: id)) else { return nil }
        guard job.id == id else { throw PackageModelError.invalidCheckpoint }
        return job
    }

    public func save(_ job: PackageJob) throws {
        try PackageRecovery.save(job, to: checkpointURL(id: job.id))
    }

    public func selectedID() throws -> UUID? {
        guard FileManager.default.fileExists(atPath: selectionURL.path) else { return nil }
        _ = try PackageRecovery.fileSize(selectionURL)
        return try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL)).id
    }

    public func select(_ id: UUID?) throws {
        if let id { guard try load(id: id) != nil else { throw PackageModelError.invalidCheckpoint } }
        try writeSelection(id)
    }

    private func writeSelection(_ id: UUID?) throws {
        try JSONEncoder().encode(Selection(id: id)).write(to: selectionURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: selectionURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// The library exposes one latest snapshot per album; older immutable exports remain on disk.
    public func entries() throws -> [PackageLibraryEntry] {
        let snapshots = try allEntries()
        var latest: [UUID: PackageLibraryEntry] = [:]
        for entry in snapshots {
            let key = entry.stableAlbumID
            if let current = latest[key] {
                if entry.revision > current.revision || (entry.revision == current.revision && entry.createdAt > current.createdAt) {
                    latest[key] = entry
                }
            } else { latest[key] = entry }
        }
        return latest.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    public func latest(albumID: UUID) throws -> PackageJob? {
        try entries().first { $0.stableAlbumID == albumID }?.job
    }

    public func allEntries() throws -> [PackageLibraryEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { url -> PackageLibraryEntry? in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                do {
                    guard let job = try load(id: id) else { return nil }
                    return PackageLibraryEntry(job: job)
                } catch {
                    let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    return PackageLibraryEntry(unavailableID: id, createdAt: date,
                        issue: "这个照片包的记录无法读取。原文件已保留，可单独删除这个包后重新选择照片。")
                }
            }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    public func delete(id: UUID) throws {
        let target = try directory(id: id)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        if (try? selectedID()) == id { try select(nil) }
    }

    public func thumbnailURL(packageID: UUID, itemID: String) throws -> URL {
        guard UUID(uuidString: itemID) != nil else { throw PackageModelError.invalidCheckpoint }
        let folder = try directory(id: packageID).appendingPathComponent("Thumbnails", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PackageModelError.invalidCheckpoint }
        }
        return folder.appendingPathComponent(itemID).appendingPathExtension("jpg")
    }

    private func isolateDamagedLegacyRecord() throws {
        _ = try PackageRecovery.fileSize(legacyURL)
        let data = try Data(contentsOf: legacyURL)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var id = (object?["id"] as? String).flatMap(UUID.init(uuidString:))
        if id == nil {
            // Before libraries existed there was at most one UUID workspace.
            // Associate it only when unambiguous and it has no migrated journal.
            let candidates = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.lastPathComponent) }
                .filter { candidate in
                    guard let url = try? checkpointURL(id: candidate) else { return false }
                    return !FileManager.default.fileExists(atPath: url.path)
                }
            if candidates.count == 1 { id = candidates[0] }
        }
        var isolatedID = id ?? UUID()
        var destination = try checkpointURL(id: isolatedID)
        if FileManager.default.fileExists(atPath: destination.path) {
            isolatedID = UUID()
            destination = try checkpointURL(id: isolatedID)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic same-volume rename keeps the exact damaged bytes for diagnosis.
        try FileManager.default.moveItem(at: legacyURL, to: destination)
        if !FileManager.default.fileExists(atPath: selectionURL.path) { try writeSelection(isolatedID) }
    }
}
