import Foundation
import SQLite3

public enum ImportHistoryError: LocalizedError {
    case storage(String)
    case unsupportedVersion
    case invalidRecord
    public var errorDescription: String? {
        switch self {
        case .storage(let detail): return "导入历史无法读写，已停止以避免重复保存：\(detail)"
        case .unsupportedVersion: return "导入历史版本暂不支持，请保留记录并更新 Dropack。"
        case .invalidRecord: return "导入历史记录不完整，已停止以避免重复保存。"
        }
    }
}

public struct ImportHistoryRecord: Equatable, Sendable {
    public enum State: String, Sendable { case unresolved, confirmed }
    public var identity: String
    public var state: State
    public var jobID: UUID
    public var itemID: String
    public var assetIdentifier: String?
}

/// Separate from the disposable current-task checkpoint. SQLite FULL transactions
/// keep a large import history incremental and survive termination between items.
/// An unresolved row is NOT evidence that a Photos transaction succeeded.
public struct ImportHistoryStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func record(for identity: String) throws -> ImportHistoryRecord? {
        try database { db in try lookup(identity, db: db) }
    }

    public func identity(source: String, itemID: String) throws -> String? {
        try database { db in
            let rows = try query("SELECT resource_identity FROM source_items WHERE source_identity = ? AND item_id = ?", [source, itemID], db: db)
            return rows.first?.first ?? nil
        }
    }

    /// Atomically reserve content before handing bytes to PhotoKit. Returning an
    /// existing row means the caller MUST NOT start another Photos transaction.
    public func begin(identity: String, jobID: UUID, itemID: String,
                      sourceIdentity: String?) throws -> ImportHistoryRecord? {
        try database { db in
            try transaction(db) {
                if let existing = try lookup(identity, db: db) {
                    try link(sourceIdentity, itemID: itemID, identity: identity, db: db)
                    return existing
                }
                try execute("INSERT INTO resources VALUES (?, 'unresolved', ?, ?, NULL)",
                            [identity, jobID.uuidString, itemID], db: db)
                try link(sourceIdentity, itemID: itemID, identity: identity, db: db)
                return nil
            }
        }
    }

    /// Call only after a successful PhotoKit callback, a durable saved checkpoint,
    /// or the user's explicit resolution of an uncertain result as already saved.
    public func confirm(identity: String, jobID: UUID, itemID: String,
                        assetIdentifier: String?, sourceIdentity: String?) throws {
        try database { db in
            try transaction(db) {
                try execute("INSERT INTO resources VALUES (?, 'confirmed', ?, ?, ?) ON CONFLICT(identity) DO UPDATE SET status = 'confirmed', asset_id = COALESCE(excluded.asset_id, resources.asset_id)",
                            [identity, jobID.uuidString, itemID, assetIdentifier], db: db)
                try link(sourceIdentity, itemID: itemID, identity: identity, db: db)
            }
        }
    }

    public func associate(identity: String, sourceIdentity: String?, itemID: String) throws {
        guard let sourceIdentity else { return }
        try database { db in
            guard try lookup(identity, db: db) != nil else { throw ImportHistoryError.invalidRecord }
            try link(sourceIdentity, itemID: itemID, identity: identity, db: db)
        }
    }

    /// Only a confirmed failure before/supplied by PhotoKit, or an explicit user
    /// decision to retry, releases the unresolved reservation. Confirmed history
    /// is never erased by retry or by clearing the current task.
    public func releaseUnresolved(identity: String) throws {
        try database { db in
            try execute("DELETE FROM resources WHERE identity = ? AND status = 'unresolved'", [identity], db: db)
        }
    }

    /// Only call after PhotoKit, with full read permission, confirms this exact
    /// asset no longer exists. Limited/inaccessible is NOT proof of deletion.
    public func forgetMissingAsset(identity: String, assetIdentifier: String) throws {
        try database { db in
            try execute("DELETE FROM resources WHERE identity = ? AND status = 'confirmed' AND asset_id = ?",
                        [identity, assetIdentifier], db: db)
        }
    }

    /// Batch lookups share one connection/transaction. The current checkpoint is
    /// deliberately independent: clearing it never removes these rows.
    public func reconcile(_ candidate: inout ImportJob, markPreviouslyImported: Bool) throws {
        try database { db in
            for index in candidate.items.indices {
                var identity = candidate.items[index].contentIdentity
                if identity == nil, let source = candidate.source.contentIdentity {
                    identity = try query("SELECT resource_identity FROM source_items WHERE source_identity = ? AND item_id = ?", [source, candidate.items[index].id], db: db).first?.first ?? nil
                }
                guard let identity, let record = try lookup(identity, db: db) else { continue }
                Self.apply(record, to: &candidate.items[index], markPreviouslyImported: markPreviouslyImported)
            }
        }
    }

    public func preserve(_ candidate: inout ImportJob) throws {
        try database { db in
            try transaction(db) {
                for index in candidate.items.indices {
                    let item = candidate.items[index]
                    guard item.state == .saved || item.state == .uncertain || item.state == .inFlight else { continue }
                    let identity = try item.contentIdentity ?? ImportContentIdentity.verifiedManifest(item)
                    guard let identity else {
                        if item.state != .saved {
                            throw ImportHistoryError.storage("请先核对旧任务中保存结果不确定的项目，再清除或更换来源。")
                        }
                        continue
                    }
                    candidate.items[index].contentIdentity = identity
                    let existing = try lookup(identity, db: db)
                    if item.state == .saved && existing?.state != .confirmed {
                        try execute("INSERT INTO resources VALUES (?, 'confirmed', ?, ?, ?) ON CONFLICT(identity) DO UPDATE SET status = 'confirmed', asset_id = COALESCE(excluded.asset_id, resources.asset_id)",
                                    [identity, candidate.id.uuidString, item.id, item.assetIdentifier], db: db)
                    } else if existing == nil {
                        try execute("INSERT INTO resources VALUES (?, 'unresolved', ?, ?, NULL)",
                                    [identity, candidate.id.uuidString, item.id], db: db)
                    }
                    try link(candidate.source.contentIdentity, itemID: item.id, identity: identity, db: db)
                }
            }
        }
    }

    public static func apply(_ record: ImportHistoryRecord, to item: inout ImportItem, markPreviouslyImported: Bool) {
        item.contentIdentity = record.identity
        if record.state == .confirmed {
            let wasSaved = item.state == .saved
            item.state = .saved
            item.assetIdentifier = record.assetIdentifier ?? item.assetIdentifier
            if markPreviouslyImported || !wasSaved { item.alreadyImported = true }
            item.errorMessage = nil
        } else {
            item.state = .uncertain
            item.errorMessage = "上次保存结果不确定。请先在相册核对，不能自动重复保存。"
        }
    }

    private func link(_ source: String?, itemID: String, identity: String, db: OpaquePointer) throws {
        guard let source else { return }
        try execute("INSERT INTO source_items VALUES (?, ?, ?) ON CONFLICT(source_identity, item_id) DO UPDATE SET resource_identity = excluded.resource_identity WHERE source_items.resource_identity != excluded.resource_identity",
                    [source, itemID, identity], db: db)
    }

    private func lookup(_ identity: String, db: OpaquePointer) throws -> ImportHistoryRecord? {
        guard let row = try query("SELECT status, job_id, item_id, asset_id FROM resources WHERE identity = ?", [identity], db: db).first else { return nil }
        guard row.count == 4, let stateText = row[0], let state = ImportHistoryRecord.State(rawValue: stateText),
              let jobText = row[1], let jobID = UUID(uuidString: jobText), let itemID = row[2] else { throw ImportHistoryError.invalidRecord }
        return .init(identity: identity, state: state, jobID: jobID, itemID: itemID, assetIdentifier: row[3])
    }

    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开历史文件"
            if let handle { sqlite3_close(handle) }
            throw ImportHistoryError.storage(detail)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode = WAL", [], db: db)
        try execute("PRAGMA synchronous = FULL", [], db: db)
        let version = try query("PRAGMA user_version", [], db: db).first?.first ?? nil
        guard version == "0" || version == "1" else { throw ImportHistoryError.unsupportedVersion }
        try execute("CREATE TABLE IF NOT EXISTS resources (identity TEXT PRIMARY KEY NOT NULL, status TEXT NOT NULL CHECK(status IN ('unresolved','confirmed')), job_id TEXT NOT NULL, item_id TEXT NOT NULL, asset_id TEXT)", [], db: db)
        try execute("CREATE TABLE IF NOT EXISTS source_items (source_identity TEXT NOT NULL, item_id TEXT NOT NULL, resource_identity TEXT NOT NULL, PRIMARY KEY(source_identity,item_id))", [], db: db)
        if version == "0" { try execute("PRAGMA user_version = 1", [], db: db) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return try body(db)
    }

    private func transaction<T>(_ db: OpaquePointer, body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", [], db: db)
        do {
            let value = try body()
            try execute("COMMIT", [], db: db)
            return value
        } catch {
            try? execute("ROLLBACK", [], db: db)
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [String?], db: OpaquePointer) throws {
        _ = try query(sql, values, db: db)
    }

    private func query(_ sql: String, _ values: [String?], db: OpaquePointer) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportHistoryError.storage(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value { result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            else { result = sqlite3_bind_null(statement, Int32(index + 1)) }
            guard result == SQLITE_OK else { throw ImportHistoryError.storage(String(cString: sqlite3_errmsg(db))) }
        }
        var rows: [[String?]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    guard let text = sqlite3_column_text(statement, column) else { return nil }
                    return String(cString: text)
                })
            case SQLITE_DONE: return rows
            default: throw ImportHistoryError.storage(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

/// Owns all app history I/O off MainActor. Batch methods copy the value-type job
/// once and use one connection, rather than synchronously reopening SQLite per
/// photo during launch. A confirmed row is not rewritten on every restoration.
public actor ImportHistoryWorker {
    private let store: ImportHistoryStore
    public init(store: ImportHistoryStore) { self.store = store }
    public func record(for identity: String) throws -> ImportHistoryRecord? { try store.record(for: identity) }
    public func begin(identity: String, jobID: UUID, itemID: String, sourceIdentity: String?) throws -> ImportHistoryRecord? {
        try store.begin(identity: identity, jobID: jobID, itemID: itemID, sourceIdentity: sourceIdentity)
    }
    public func confirm(identity: String, jobID: UUID, itemID: String, assetIdentifier: String?, sourceIdentity: String?) throws {
        try store.confirm(identity: identity, jobID: jobID, itemID: itemID, assetIdentifier: assetIdentifier, sourceIdentity: sourceIdentity)
    }
    public func associate(identity: String, sourceIdentity: String?, itemID: String) throws {
        try store.associate(identity: identity, sourceIdentity: sourceIdentity, itemID: itemID)
    }
    public func releaseUnresolved(identity: String) throws { try store.releaseUnresolved(identity: identity) }
    public func forgetMissingAsset(identity: String, assetIdentifier: String) throws {
        try store.forgetMissingAsset(identity: identity, assetIdentifier: assetIdentifier)
    }
    public func reconcile(_ job: ImportJob, markPreviouslyImported: Bool) throws -> ImportJob {
        var result = job
        try store.reconcile(&result, markPreviouslyImported: markPreviouslyImported)
        return result
    }
    public func preserve(_ job: ImportJob) throws -> ImportJob {
        var result = job
        try store.preserve(&result)
        return result
    }
    public func restore(_ job: ImportJob) throws -> ImportJob {
        var result = job
        try store.preserve(&result)
        try store.reconcile(&result, markPreviouslyImported: false)
        return result
    }
}
