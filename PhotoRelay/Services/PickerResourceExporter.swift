import Foundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// Captures one private picker selection into its package's durable source folder.
/// Never retains an NSItemProvider temporary URL after its completion returns.
enum PickerResourceExporter {
    struct Output: Sendable {
        let file: URL
        let pairedVideo: URL?
        let originalProgress: PackageOriginalProgress
    }

    static func capture(_ selected: PhotoPickerSelection.Item, directory: URL,
                        readProgress: @escaping @Sendable (UInt64) -> Void = { _ in },
                        originalProgress: @escaping @Sendable (PackageOriginalProgress, UInt64?) -> Void = { _, _ in },
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if selected.provider.canLoadObject(ofClass: PHLivePhoto.self) {
            // The opaque provider step is preparation, never proof of iCloud.
            // The two PhotoKit resources can independently prove network need.
            let originals = PackageOriginalProgressTracker(resourceCount: 3)
            originals.report(resource: 0) { originalProgress($0, nil) }
            let request = PickerProviderRequest<PHLivePhoto>()
            let live = try await request.perform(start: {
                selected.provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                    request.receive(error: error) {
                        guard let live = object as? PHLivePhoto else { throw PhotoPackageError.unsupported("实况照片") }
                        return live
                    }
                }
            }, progress: { fraction in
                originals.report(resource: 0, fraction: fraction) { original in
                    originalProgress(original, nil); progress(original.fraction ?? 0)
                }
            })
            originals.report(resource: 0, completed: true) { originalProgress($0, nil) }
            let resources = PHAssetResource.assetResources(for: live)
            guard let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
                  let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
                throw PhotoPackageError.unsupported("实况照片")
            }
            let stillURL = directory.appendingPathComponent("original").appendingPathExtension(fileExtension(photo, kind: .photo))
            let movieURL = directory.appendingPathComponent("paired").appendingPathExtension(fileExtension(video, kind: .video))
            do {
                for (offset, resourceAndURL) in [(photo, stillURL), (video, movieURL)].enumerated() {
                    let (resource, destination) = resourceAndURL
                    let resourceIndex = offset + 1
                    originals.report(resource: resourceIndex) { originalProgress($0, 0) }
                    let result = try await PhotoResourceLocalFirst.export(destination: destination,
                        safetyMargin: 256 * 1024 * 1024, onNetworkRequired: {
                            originals.report(resource: resourceIndex, cloudConfirmed: true) { originalProgress($0, nil) }
                        }) { stream, networkAllowed in
                        try await stream.export(resource: resource, isNetworkAccessAllowed: networkAllowed,
                            readProgress: { bytes in
                                originals.report(resource: resourceIndex) { originalProgress($0, bytes) }
                                readProgress(bytes)
                            }) { fraction in
                                originals.report(resource: resourceIndex, fraction: fraction,
                                    cloudConfirmed: networkAllowed) { original in
                                    originalProgress(original, nil); progress(original.fraction ?? 0)
                                }
                            }
                    }
                    guard result.byteCount > 0 else { throw PhotoPackageError.emptyResource(resource.originalFilename) }
                    originals.report(resource: resourceIndex, completed: true) { original in
                        // The enclosing package publishes ready after the source
                        // bookmarks and journal have been saved successfully.
                        if original.state != .ready { originalProgress(original, nil) }
                    }
                }
                return Output(file: stillURL, pairedVideo: movieURL, originalProgress: originals.snapshot)
            } catch {
                try? FileManager.default.removeItem(at: stillURL)
                try? FileManager.default.removeItem(at: movieURL)
                throw error
            }
        }
        let kind = selected.kind
        guard let identifier = selected.provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier), let ext = type.preferredFilenameExtension else { return false }
            return MediaPolicy.kind(for: "asset." + ext) == kind
        }) ?? selected.provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: kind == .photo ? .image : .movie) == true && $0 != UTType.livePhoto.identifier
        }) else { throw PhotoPackageError.unsupported("所选项目") }
        let originals = PackageOriginalProgressTracker(resourceCount: 2)
        originals.report(resource: 0) { originalProgress($0, nil) }
        let request = PickerProviderRequest<URL>()
        let file = try await request.perform(start: {
            selected.provider.loadFileRepresentation(forTypeIdentifier: identifier) { temporary, error in
                request.receive(error: error) {
                    guard let temporary else { throw PhotoPackageError.missingAsset }
                    let originalExtension = temporary.pathExtension.lowercased()
                    let ext = MediaPolicy.kind(for: "asset." + originalExtension) == kind
                        ? originalExtension : (UTType(identifier)?.preferredFilenameExtension ?? "")
                    guard MediaPolicy.kind(for: "asset." + ext) == kind else { throw PhotoPackageError.unsupported("所选项目") }
                    let target = directory.appendingPathComponent("original").appendingPathExtension(ext)
                    originals.report(resource: 0, completed: true) { originalProgress($0, nil) }
                    try copy(temporary, to: target, isCancelled: { request.isCancelled }, progress: { fraction in
                        originals.report(resource: 1, fraction: fraction) { original in
                            originalProgress(original, nil); progress(original.fraction ?? 0)
                        }
                    })
                    return target
                }
            }
        }, progress: { fraction in
            originals.report(resource: 0, fraction: fraction) { original in
                originalProgress(original, nil); progress(original.fraction ?? 0)
            }
        })
        originals.report(resource: 1, completed: true) { _ in }
        return Output(file: file, pairedVideo: nil, originalProgress: originals.snapshot)
    }

    private static func fileExtension(_ resource: PHAssetResource, kind: MediaKind) -> String {
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        if MediaPolicy.kind(for: "asset." + ext) == kind { return ext }
        return UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? (kind == .photo ? "heic" : "mov")
    }

    /// Synchronous on the provider callback, so its temporary lease remains valid.
    /// Writes at most 1 MiB at a time and atomically publishes only complete files.
    static func copy(_ source: URL, to destination: URL, isCancelled: () -> Bool,
                     progress: @Sendable (Double) -> Void) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let bytes = try PackageRecovery.fileSize(source)
        guard bytes > 0 else { throw PhotoPackageError.emptyResource(source.lastPathComponent) }
        let partial = destination.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw PhotoPackageError.disk("")
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        var copied: UInt64 = 0
        var checkedAt: UInt64 = 0
        var lastProgress = -Double.infinity
        while copied < bytes {
            guard !isCancelled() else { throw CancellationError() }
            if copied == 0 || copied - checkedAt >= 64 * 1024 * 1024 {
                try PhotoResourceStream.checkSpace(required: 256 * 1024 * 1024, at: destination.deletingLastPathComponent())
                checkedAt = copied
            }
            try autoreleasepool {
                guard let data = try input.read(upToCount: Int(min(bytes - copied, 1024 * 1024))), !data.isEmpty else {
                    throw PhotoPackageError.emptyResource(source.lastPathComponent)
                }
                try output.write(contentsOf: data)
                copied += UInt64(data.count)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.1 { lastProgress = now; progress(Double(copied) / Double(bytes)) }
        }
        guard !isCancelled() else { throw CancellationError() }
        try output.synchronize(); try output.close()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

/// Coordinates cancellation with provider callbacks. A cancelled callback cannot
/// recreate files after its enclosing operation has returned and cleaned up.
final class PickerProviderRequest<Value>: @unchecked Sendable {
    private let operation = CancellableCallbackOperation<Value>()
    var isCancelled: Bool { operation.isCancelled }

    func perform(start: @escaping () -> Progress,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> Value {
        try await operation.wait {
            let request = start()
            let observation = request.observe(\.fractionCompleted, options: [.new]) { [operation] value, _ in
                // KVO progress owns accepted callback work just like provider
                // copying, so a delayed report cannot outlive this request.
                operation.process { progress(value.fractionCompleted) }
            }
            operation.registerTermination {
                observation.invalidate()
                request.cancel()
            }
        }
    }

    func receive(error: Error?, transform: () throws -> Value) {
        operation.complete {
            if let error { throw error }
            return try transform()
        }
    }
}
