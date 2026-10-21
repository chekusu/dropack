import Foundation

public enum CheckpointError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidJournal
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "进度记录版本 \(version) 暂不支持。请保留记录并更新应用。"
        case .invalidJournal: return "进度记录无法读取。为避免重复导入，请先核对相册。"
        }
    }
}

/// Atomic replacement: a failed journal write stops importing before another Photos transaction.
public struct CheckpointStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ImportJob? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var job = try JSONDecoder().decode(ImportJob.self, from: Data(contentsOf: url))
        guard job.version == 1 else { throw CheckpointError.unsupportedVersion(job.version) }
        guard Set(job.items.map(\.id)).count == job.items.count,
              job.delaySeconds.isFinite, (0...10).contains(job.delaySeconds) else { throw CheckpointError.invalidJournal }
        job.recoverAfterInterruption()
        return job
    }

    public func save(_ job: ImportJob) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(job)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
