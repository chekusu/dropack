import Foundation

/// Each received album owns its checkpoint. Switching the selected task cannot
/// erase a paused import; clearing/deleting an album never erases content receipts.
public struct ReceivedAlbumStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> [ImportJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var albums: [ImportJob] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard var job = try CheckpointStore(url: url).load() else { continue }
            job.migrateImportPurpose()
            if job.isSharedAlbum { albums.append(job) }
            else {
                // Move obsolete ordinary-source library entries to resumable task
                // storage before removing their old copy. Never discard receipts.
                try save(job)
                try CheckpointStore(url: url).remove()
            }
        }
        return albums.sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ job: ImportJob) throws {
        var classified = job
        classified.migrateImportPurpose()
        let root = classified.isSharedAlbum ? directory : oneTimeDirectory
        try CheckpointStore(url: root.appendingPathComponent(classified.albumID.uuidString + ".json")).save(classified)
    }

    /// These are checkpoints, not user-visible shared albums. Retaining them makes
    /// switching sources reversible until the user finishes or clears the import.
    public func loadOneTimeImports() throws -> [ImportJob] {
        guard FileManager.default.fileExists(atPath: oneTimeDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: oneTimeDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try CheckpointStore(url: $0).load() }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func removeOneTimeImport(jobID: UUID) throws {
        try CheckpointStore(url: oneTimeDirectory.appendingPathComponent(jobID.uuidString + ".json")).remove()
    }

    private var oneTimeDirectory: URL { directory.appendingPathComponent("one-time-imports", isDirectory: true) }

    public func remove(albumID: UUID) throws {
        try CheckpointStore(url: directory.appendingPathComponent(albumID.uuidString + ".json")).remove()
    }

    /// Stable identity is album metadata, never the human-facing title. Equal or
    /// older revisions cannot replace a newer snapshot, including a late AirDrop.
    public static func shouldKeepExisting(_ existing: ImportJob, incoming: ImportJob) -> Bool {
        guard existing.isSharedAlbum, incoming.isSharedAlbum, existing.albumID == incoming.albumID,
              let old = existing.album, let new = incoming.album else { return false }
        return old.revision >= new.revision
    }
}
