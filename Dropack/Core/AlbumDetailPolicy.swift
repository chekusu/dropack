import Foundation

/// Actions describe intent, never a completed status. A paused first import is
/// still a sync; only a persisted transition from an earlier local album can
/// represent an update. Global deduplication is not evidence of that transition.
public enum AlbumDetailAction: Equatable, Sendable {
    case synchronize, update, save, finish

    public var titleKey: String {
        switch self {
        case .synchronize: return "同步到相册"
        case .update: return "更新到相册"
        case .save: return "保存到相册"
        case .finish: return "完成"
        }
    }
}

public enum AlbumDetailPolicy {
    public static func primaryAction(for job: ImportJob) -> AlbumDetailAction {
        guard job.isSharedAlbum else {
            return job.phase == .completed && !job.hasUnresolvedItems ? .finish : .save
        }
        return job.isAlbumUpdate == true && job.phase != .completed ? .update : .synchronize
    }

    /// Reconnecting an archive is useful for pending imports or forwarding, but
    /// cannot make a fully synchronized album's bottom action available again.
    public static func canPerformPrimaryAction(for job: ImportJob, canStart: Bool, needsRelink: Bool) -> Bool {
        if job.isSharedAlbum && !job.hasUnresolvedItems { return false }
        return primaryAction(for: job) == .finish || canStart || needsRelink
    }

    /// Only actual media capture dates belong in a detail-page date range. The
    /// file modification time and archive creation time are not capture dates.
    public static func captureDateRange(_ dates: [Date]) -> ClosedRange<Date>? {
        let valid = dates.filter { $0.timeIntervalSinceReferenceDate.isFinite }
        guard let first = valid.min(), let last = valid.max() else { return nil }
        return first...last
    }
}
