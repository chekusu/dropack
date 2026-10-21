import Foundation
import Photos

enum PhotoLibraryWriterError: LocalizedError {
    case permissionDenied
    case transactionAlreadyRunning
    case transactionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "请在“设置 → 隐私与安全性 → 照片”中允许 Dropack 添加照片。"
        case .transactionAlreadyRunning:
            return "已有文件正在写入相册，请等待它完成。"
        case .transactionFailed(let details):
            return "相册保存失败：\(details)"
        }
    }
}

protocol PhotoLibraryWriting: Sendable {
    func authorizeAlbumLink() async
    func authorize() async throws
    func save(item: ImportItem, fileURL: URL, pairedVideoURL: URL?) async throws -> String?
    func assetPresence(_ identifier: String) async -> SystemAssetPresence
    func ensureAlbum(id: UUID, title: String) async throws -> String?
    func addToAlbum(assetIdentifiers: [String], id: UUID, title: String) async throws -> String?
    func albumPresence(id: UUID) async throws -> SystemAssetPresence
    func albumMembers(id: UUID) async throws -> [String]?
}

extension PhotoLibraryWriting {
    func authorizeAlbumLink() async {}
    // Existing/mock writers conservatively preserve confirmed receipts when
    // they cannot inspect Photos, rather than producing duplicate transactions.
    func assetPresence(_ identifier: String) async -> SystemAssetPresence { .unknown }
    func ensureAlbum(id: UUID, title: String) async throws -> String? { nil }
    func addToAlbum(assetIdentifiers: [String], id: UUID, title: String) async throws -> String? { nil }
    func albumPresence(id: UUID) async throws -> SystemAssetPresence { .unknown }
    func albumMembers(id: UUID) async throws -> [String]? { nil }
}

/// PhotoKit reads one staged file at a time; no image decoding or full-file Data allocation.
actor PhotoLibraryWriter: PhotoLibraryWriting {
    private var transactionRunning = false

    /// Ask only when the user explicitly synchronizes a sharing album. Requesting
    /// permission must not create an empty collection before any media is saved.
    func authorizeAlbumLink() async {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
    }

    func assetPresence(_ identifier: String) async -> SystemAssetPresence {
        await SystemAlbumService.shared.assetPresence(identifier)
    }

    func albumPresence(id: UUID) async throws -> SystemAssetPresence {
        try await SystemAlbumService.shared.albumPresence(albumID: id)
    }

    func albumMembers(id: UUID) async throws -> [String]? {
        try await SystemAlbumService.shared.members(albumID: id)
    }

    func ensureAlbum(id: UUID, title: String) async throws -> String? {
        try await SystemAlbumService.shared.ensureAlbum(albumID: id, title: title, requestAuthorization: true)
    }

    func addToAlbum(assetIdentifiers: [String], id: UUID, title: String) async throws -> String? {
        guard !assetIdentifiers.isEmpty else { return nil }
        return try await SystemAlbumService.shared.add(assetIdentifiers: assetIdentifiers, to: id, title: title)
    }

    func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { result in
                    continuation.resume(returning: result)
                }
            }
        }
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryWriterError.permissionDenied
        }
    }

    func save(item: ImportItem, fileURL: URL, pairedVideoURL: URL? = nil) async throws -> String? {
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        guard !transactionRunning else { throw PhotoLibraryWriterError.transactionAlreadyRunning }
        transactionRunning = true
        defer { transactionRunning = false }
        let captureDate: Date?
        if let creationDate = item.creationDate { captureDate = creationDate }
        else { captureDate = await MediaCaptureDate.read(fileURL, kind: item.kind) ?? item.modifiedAt }

        let identifier = AssetIdentifierBox()
        // Deliberately do not cancel this continuation: PhotoKit may still be reading fileURL.
        // The controller keeps the file until this completion and its durable checkpoint.
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = captureDate
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = (item.relativePath as NSString).lastPathComponent
                request.addResource(with: item.kind == .photo ? .photo : .video,
                                    fileURL: fileURL, options: options)
                if let pairedVideoURL, let pairedVideo = item.pairedVideo {
                    let pairedOptions = PHAssetResourceCreationOptions()
                    pairedOptions.shouldMoveFile = false
                    pairedOptions.originalFilename = (pairedVideo.relativePath as NSString).lastPathComponent
                    request.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: pairedOptions)
                }
                identifier.set(request.placeholderForCreatedAsset?.localIdentifier)
            } completionHandler: { succeeded, error in
                if succeeded {
                    continuation.resume(returning: identifier.get())
                } else {
                    continuation.resume(throwing: PhotoLibraryWriterError.transactionFailed(
                        error?.localizedDescription ?? "系统未提供错误详情。"))
                }
            }
        }
    }
}

private final class AssetIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?

    func set(_ value: String?) {
        lock.lock()
        identifier = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return identifier
    }
}
