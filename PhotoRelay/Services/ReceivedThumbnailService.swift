import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Serial, disk-backed previews. A scrolling grid never retains original media
/// bytes or extracts several video originals at once.
actor ReceivedThumbnailService {
    let directory: URL
    private let loader = MediaThumbnailLoader()
    private let sourceService = MediaSourceService()
    private var tail: Task<URL?, Never>?

    init(directory: URL) { self.directory = directory }

    func load(item: ImportItem, source: SourceDescriptor) async -> URL? {
        let destination = path(item)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let previous = tail
        let next = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self else { return nil as URL? }
            return await self.render(item: item, source: source)
        }
        tail = next
        return await next.value
    }

    func cache(_ image: CGImage, item: ImportItem) -> URL? {
        let destination = path(item)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(output) ? destination : nil
    }

    private func render(item: ImportItem, source: SourceDescriptor) async -> URL? {
        let destination = path(item)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: source.bookmark, options: .withoutUI,
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        guard let file = try? await sourceService.previewFile(item: item, source: url, kind: source.kind, directory: scratch) else { return nil }
        defer { if source.kind == .zip { try? FileManager.default.removeItem(at: file) } }
        guard let bitmap = await loader.thumbnail(fileURL: file, kind: item.previewPath == nil ? item.kind : .photo) else { return nil }
        return cache(bitmap, item: item)
    }

    private func path(_ item: ImportItem) -> URL {
        let key = item.contentIdentity ?? item.id
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".jpg")
    }
}
