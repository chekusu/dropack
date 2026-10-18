import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Ephemeral presentation data, never written to the checkpoint or fetched from
/// the user's Photos library. Only a downsampled bitmap reaches the main actor.
struct ImportPreview: Identifiable {
    let id: UUID
    let itemID: String
    let title: String
    let kind: MediaKind
    var image: UIImage?
}

/// One already-staged resource at a time. ImageIO reads directly from the URL;
/// UIImage(contentsOfFile:) and whole-file Data would decode/load large originals.
protocol MediaThumbnailGenerating: Sendable {
    func thumbnail(fileURL: URL, kind: MediaKind) async -> CGImage?
}

actor MediaThumbnailLoader: MediaThumbnailGenerating {
    static let maximumPixelSize = 360

    func thumbnail(fileURL: URL, kind: MediaKind) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let result: CGImage?
        switch kind {
        case .photo:
            result = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
        case .video:
            result = await videoThumbnail(fileURL: fileURL)
        }
        return Task.isCancelled ? nil : result
    }

    private func videoThumbnail(fileURL: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.maximumSize = CGSize(width: Self.maximumPixelSize, height: Self.maximumPixelSize)
        generator.appliesPreferredTrackTransform = true
        // Cancel the preview after a small budget. Unsupported/slow video codecs
        // must not hold up the real import, and no preview error escapes this API.
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    guard !Task.isCancelled else { return nil }
                    do {
                        let result = try await generator.image(at: .zero)
                        return Task.isCancelled ? nil : result.image
                    } catch { return nil }
                } onCancel: {
                    generator.cancelAllCGImageGeneration()
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// A visible view waits for the packaging worker's small JPEG without asking
/// PhotoKit or a file provider to regenerate a missing preview on every retry.
/// Only cache existence is polled, with at most two checks per second initially
/// and a two-second interval thereafter. SwiftUI cancels the wait offscreen.
@MainActor
enum PackageThumbnailAvailability {
    static func waitForAvailable(
        loadOnce: () async -> URL?,
        cachedURL: () -> URL?,
        shouldWait: () -> Bool,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> URL? {
        guard !Task.isCancelled else { return nil }
        // ZIP append can occupy the packaging actor for a large video. Existing
        // tiny previews must remain available without waiting for that actor.
        if let available = cachedURL() { return available }
        let initialURL = await loadOnce()
        guard !Task.isCancelled else { return nil }
        if let initialURL { return initialURL }
        var delay: Duration = .milliseconds(500)
        while !Task.isCancelled {
            // Check once more even when the worker just paused or finished: it
            // may have published the preview immediately before becoming idle.
            if let available = cachedURL() { return available }
            guard shouldWait() else { return nil }
            do { try await sleep(delay) }
            catch { return nil }
            delay = min(.seconds(2), delay * 2)
        }
        return nil
    }
}
