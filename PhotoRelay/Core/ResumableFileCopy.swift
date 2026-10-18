import Foundation

public enum ResumableCopyError: Error {
    case sourceChanged
    case sourceReadFailed(String)
    case destinationWriteFailed(String)
}

/// Resumes the local staging copy, never a PhotoKit transaction. Before appending,
/// compare the entire retained prefix with the source using bounded buffers. A
/// reconnected device with a different same-name/size/date file cannot splice data
/// into an existing partial file. Verification rereads that prefix from the device;
/// only the remaining bytes are written again to iPhone storage.
public enum ResumableFileCopy {
    @discardableResult
    public static func copy(from source: URL, to destination: URL, expectedBytes: UInt64,
                            chunkSize: Int = 256 * 1024,
                            checkCancellation: () throws -> Void = { try Task.checkCancellation() },
                            verificationProgress: (UInt64, UInt64) -> Void = { _, _ in },
                            consume: (Data) -> Void = { _ in },
                            progress: (UInt64) -> Void = { _ in }) throws -> UInt64 {
        precondition(chunkSize > 0)
        try checkCancellation()
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) }
        catch { throw ResumableCopyError.sourceReadFailed(error.localizedDescription) }
        defer { try? input.close() }
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ResumableCopyError.destinationWriteFailed("无法创建临时文件。")
            }
        }
        let output: FileHandle
        do { output = try FileHandle(forUpdating: destination) }
        catch { throw ResumableCopyError.destinationWriteFailed(error.localizedDescription) }
        // Persist a usable prefix even if cancellation or an unplug ends the copy.
        defer { try? output.synchronize(); try? output.close() }
        let retained: UInt64
        do { retained = try output.seekToEnd(); try output.seek(toOffset: 0) }
        catch { throw ResumableCopyError.destinationWriteFailed(error.localizedDescription) }
        guard retained <= expectedBytes else { throw ResumableCopyError.sourceChanged }

        var verified: UInt64 = 0
        while verified < retained {
            try autoreleasepool {
                try checkCancellation()
                let count = Int(min(UInt64(chunkSize), retained - verified))
                let original = try readExactly(input, count: count, source: true)
                let partial = try readExactly(output, count: count, source: false)
                guard original.count == count, original == partial else { throw ResumableCopyError.sourceChanged }
                consume(original)
                verified += UInt64(count)
                verificationProgress(verified, retained)
            }
        }
        var written = retained
        progress(written)
        while written < expectedBytes {
            try autoreleasepool {
                try checkCancellation()
                let count = Int(min(UInt64(chunkSize), expectedBytes - written))
                let data = try readExactly(input, count: count, source: true)
                guard data.count == count else { throw ResumableCopyError.sourceChanged }
                do { try output.write(contentsOf: data) }
                catch { throw ResumableCopyError.destinationWriteFailed(error.localizedDescription) }
                written += UInt64(data.count)
                consume(data)
                progress(written)
            }
        }
        try checkCancellation()
        guard try readExactly(input, count: 1, source: true).isEmpty else {
            throw ResumableCopyError.sourceChanged
        }
        do { try output.synchronize() }
        catch { throw ResumableCopyError.destinationWriteFailed(error.localizedDescription) }
        return retained
    }

    private static func readExactly(_ handle: FileHandle, count: Int, source: Bool) throws -> Data {
        var result = Data()
        do {
            while result.count < count {
                let next = try autoreleasepool { try handle.read(upToCount: count - result.count) ?? Data() }
                if next.isEmpty { break }
                result.append(next)
            }
        } catch {
            if source { throw ResumableCopyError.sourceReadFailed(error.localizedDescription) }
            throw ResumableCopyError.destinationWriteFailed(error.localizedDescription)
        }
        return result
    }
}
