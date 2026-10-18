import Foundation
import Photos

/// In limited-library mode an invisible asset may still exist. Never treat it as
/// deleted and reimport it merely because PhotoKit cannot currently return it.
enum SystemAssetPresence: Equatable, Sendable {
    case available, missing, unknown
}

enum SystemAlbumServiceError: Error, LocalizedError {
    case invalidMapping
    case unavailableAssets
    case transactionFailed(String)
    case missingCollectionIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidMapping: return "系统相册关联记录无法读取，原照片没有改动。"
        case .unavailableAssets: return "部分照片已不在系统相册中，请刷新后重试。"
        case .transactionFailed(let details): return "系统相册更新失败：\(details)"
        case .missingCollectionIdentifier: return "系统未返回新相册的关联信息，请重试。"
        }
    }
}

/// Local-only mapping from portable sharing-album IDs to ordinary Photos albums.
/// This never creates an iCloud Shared Album, imports media, or deletes originals.
actor SystemAlbumService {
    static let shared = SystemAlbumService()

    private struct Mapping: Codable {
        var version = 1
        var albums: [String: String] = [:]
    }

    private let root: URL
    private var mapping: Mapping?
    private var mappingDirty = false
    // An actor alone is not enough: PhotoKit callbacks suspend and allow another
    // ensureAlbum call in. Serialize transactions so one album cannot be created
    // twice while its first creation is awaiting a callback.
    private var transactionRunning = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dropack", isDirectory: true)
    }

    /// Returns nil when full read/write access is unavailable. Callers may still
    /// save media through their add-only writer; they must not claim album linking.
    func ensureAlbum(albumID: UUID, title: String, assetIdentifiers: [String] = [],
                     requestAuthorization: Bool = false) async throws -> String? {
        await acquireTransaction()
        defer { releaseTransaction() }
        try Task.checkCancellation()
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if requestAuthorization && status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized else { return nil }
        try Task.checkCancellation()
        try loadMappingIfNeeded()
        if mappingDirty { try persistMapping() }

        let uniqueIdentifiers = Array(Set(assetIdentifiers)).sorted()
        guard uniqueIdentifiers.allSatisfy({ !$0.isEmpty }) else { throw SystemAlbumServiceError.unavailableAssets }
        let assets = Self.fetchAssets(uniqueIdentifiers)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        guard assets.count == uniqueIdentifiers.count else { throw SystemAlbumServiceError.unavailableAssets }
        let displayTitle = try Self.displayTitle(title)
        let existingID = mapping?.albums[albumID.uuidString]
        let existingCollection = existingID.flatMap(Self.fetchCollection)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }

        if let collection = existingCollection {
            guard assets.isEmpty || collection.canPerform(.addContent),
                  collection.localizedTitle == displayTitle || collection.canPerform(.rename) else {
                throw SystemAlbumServiceError.transactionFailed("这个系统相册暂不支持编辑。")
            }
            if collection.localizedTitle != displayTitle || !assets.isEmpty {
                let submitted = SystemAlbumIdentifierBox()
                try await performChanges {
                    guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                    submitted.set(collection.localIdentifier)
                    request.title = displayTitle
                    // Album membership is a set. Adding an existing asset again
                    // does not create an asset or duplicate its membership. Avoid
                    // fetching every existing member for each one-item import.
                    if !assets.isEmpty { request.addAssets(assets as NSArray) }
                }
                // A change request can be unavailable after a concurrent user
                // deletion. Confirm the result rather than reporting false success.
                guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
                guard submitted.get() != nil,
                      let refreshed = Self.fetchCollection(collection.localIdentifier),
                      refreshed.localizedTitle == displayTitle else {
                    throw SystemAlbumServiceError.transactionFailed("请刷新相册后重试。")
                }
            }
            return collection.localIdentifier
        }

        let identifier = SystemAlbumIdentifierBox()
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: displayTitle)
            identifier.set(request.placeholderForCreatedAssetCollection.localIdentifier)
            if !assets.isEmpty { request.addAssets(assets as NSArray) }
        }
        guard let collectionID = identifier.get() else { throw SystemAlbumServiceError.missingCollectionIdentifier }
        // Keep the new identifier in memory even if the durable write fails. The
        // next call retries that write and reuses the album, without claiming the
        // failed attempt succeeded or creating another one in this process.
        mapping?.albums[albumID.uuidString] = collectionID
        mappingDirty = true
        try persistMapping()
        return collectionID
    }

    /// nil means inaccessible/unlinked/deleted collection; [] is an accessible,
    /// genuinely empty album. Callers must not turn nil into a membership removal.
    func members(albumID: UUID) async throws -> [String]? {
        await acquireTransaction()
        defer { releaseTransaction() }
        try Task.checkCancellation()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        try loadMappingIfNeeded()
        if mappingDirty { try persistMapping() }
        guard let localID = mapping?.albums[albumID.uuidString],
              let collection = Self.fetchCollection(localID) else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var identifiers: [String] = []
        result.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        return identifiers
    }

    /// The same visibility distinction applies to an album collection. Receivers
    /// use this to offer a membership-only repair after a user deletes the linked
    /// album, without mistaking limited access for deletion or rewriting media.
    func albumPresence(albumID: UUID) async throws -> SystemAssetPresence {
        await acquireTransaction()
        defer { releaseTransaction() }
        try Task.checkCancellation()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return .unknown }
        try loadMappingIfNeeded()
        if mappingDirty { try persistMapping() }
        let collection = mapping?.albums[albumID.uuidString].flatMap(Self.fetchCollection)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return .unknown }
        return collection == nil ? .missing : .available
    }

    /// Reuses assets already in Photos instead of writing duplicate resources.
    func add(assetIdentifiers: [String], to albumID: UUID, title: String) async throws -> String? {
        try await ensureAlbum(albumID: albumID, title: title, assetIdentifiers: assetIdentifiers)
    }

    /// Removes membership only. Never calls PHAssetChangeRequest.deleteAssets:
    /// the camera roll and every other album keep their original media.
    /// A false result means full Photos access was unavailable, not an empty album.
    func remove(assetIdentifiers: [String], from albumID: UUID) async throws -> Bool {
        await acquireTransaction()
        defer { releaseTransaction() }
        try Task.checkCancellation()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return false }
        try loadMappingIfNeeded()
        if mappingDirty { try persistMapping() }
        guard let identifier = mapping?.albums[albumID.uuidString],
              let collection = Self.fetchCollection(identifier) else {
            throw SystemAlbumServiceError.unavailableAssets
        }
        let identifiers = Set(assetIdentifiers)
        guard !identifiers.contains("") else { throw SystemAlbumServiceError.unavailableAssets }
        guard !identifiers.isEmpty else { return true }
        guard collection.canPerform(.removeContent) else {
            throw SystemAlbumServiceError.transactionFailed("这个系统相册暂不支持编辑。")
        }
        // Only remove actual members, so an already-removed item is idempotent.
        var members: [PHAsset] = []
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
            if identifiers.contains(asset.localIdentifier) { members.append(asset) }
        }
        guard !members.isEmpty else { return true }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return false }
        try Task.checkCancellation()
        let submitted = SystemAlbumIdentifierBox()
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            submitted.set(identifier)
            request.removeAssets(members as NSArray)
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return false }
        guard submitted.get() != nil, let refreshed = Self.fetchCollection(identifier) else {
            throw SystemAlbumServiceError.transactionFailed("请刷新相册后重试。")
        }
        var remaining = false
        PHAsset.fetchAssets(in: refreshed, options: nil).enumerateObjects { asset, _, stop in
            if identifiers.contains(asset.localIdentifier) { remaining = true; stop.pointee = true }
        }
        guard !remaining else { throw SystemAlbumServiceError.transactionFailed("请刷新相册后重试。") }
        return true
    }

    func rename(albumID: UUID, title: String) async throws {
        await acquireTransaction()
        defer { releaseTransaction() }
        try Task.checkCancellation()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        try loadMappingIfNeeded()
        if mappingDirty { try persistMapping() }
        // Renaming a local Files-origin album must not create a Photos album or
        // silently turn on system-library linking.
        guard let identifier = mapping?.albums[albumID.uuidString],
              let collection = Self.fetchCollection(identifier) else { return }
        let displayTitle = try Self.displayTitle(title)
        guard collection.localizedTitle != displayTitle else { return }
        guard collection.canPerform(.rename) else {
            throw SystemAlbumServiceError.transactionFailed("这个系统相册暂不支持编辑。")
        }
        let submitted = SystemAlbumIdentifierBox()
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            submitted.set(identifier)
            request.title = displayTitle
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        guard submitted.get() != nil, Self.fetchCollection(identifier)?.localizedTitle == displayTitle else {
            throw SystemAlbumServiceError.transactionFailed("请刷新相册后重试。")
        }
    }

    func assetPresence(_ identifier: String) async -> SystemAssetPresence {
        guard !identifier.isEmpty else { return .unknown }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return .unknown }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        if asset != nil { return .available }
        return status == .authorized && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            ? .missing : .unknown
    }

    private var mappingURL: URL { root.appendingPathComponent("system-albums.json") }

    private func loadMappingIfNeeded() throws {
        guard mapping == nil else { return }
        try validateRoot()
        guard FileManager.default.fileExists(atPath: mappingURL.path) else {
            mapping = Mapping()
            return
        }
        let values = try mappingURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 8 * 1024 * 1024 else { throw SystemAlbumServiceError.invalidMapping }
        let decoded = try JSONDecoder().decode(Mapping.self, from: Data(contentsOf: mappingURL))
        guard decoded.version == 1,
              decoded.albums.allSatisfy({ UUID(uuidString: $0.key) != nil && !$0.value.isEmpty }) else {
            throw SystemAlbumServiceError.invalidMapping
        }
        mapping = decoded
    }

    private func validateRoot() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SystemAlbumServiceError.invalidMapping
            }
        }
    }

    private func persistMapping() throws {
        guard let mapping else { throw SystemAlbumServiceError.invalidMapping }
        try validateRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: mappingURL.path) {
            let values = try mappingURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SystemAlbumServiceError.invalidMapping
            }
        }
        try JSONEncoder().encode(mapping).write(to: mappingURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: mappingURL)
        defer { try? handle.close() }
        try handle.synchronize()
        mappingDirty = false
    }

    private static func displayTitle(_ title: String) throws -> String {
        try ShareAlbumMetadata(title: title).validate()
        return "Dropack · \(title)"
    }

    private static func fetchCollection(_ identifier: String) -> PHAssetCollection? {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject,
              collection.assetCollectionType == .album else { return nil }
        return collection
    }

    private static func fetchAssets(_ identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            .enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        // Once submitted, do not cancel before PhotoKit's completion callback.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { succeeded, error in
                if succeeded { continuation.resume() }
                else {
                    continuation.resume(throwing: SystemAlbumServiceError.transactionFailed(
                        error?.localizedDescription ?? "系统未提供错误详情。"))
                }
            }
        }
    }

    private func acquireTransaction() async {
        if !transactionRunning { transactionRunning = true; return }
        await withCheckedContinuation { transactionWaiters.append($0) }
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty { transactionRunning = false }
        else { transactionWaiters.removeFirst().resume() }
    }
}

private final class SystemAlbumIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
    func get() -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
