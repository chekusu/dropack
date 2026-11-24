import Foundation

/// When Dropack may ask the system for an App Store rating.
///
/// StoreKit decides whether a prompt actually appears: at most three times in
/// 365 days, never in TestFlight, and never when the person turned ratings off
/// in Settings. This policy only keeps Dropack from asking at the wrong moment.
/// It asks after an import finished and saved something new to Photos, and at
/// most once for each app version.
public enum ReviewPromptPolicy {
    public static let lastRequestedVersionKey = "dropack.reviewPrompt.lastRequestedVersion"

    public static func shouldRequest(newlySavedCount: Int, appVersion: String?,
                                     lastRequestedVersion: String?) -> Bool {
        guard newlySavedCount > 0, let version = normalized(appVersion) else { return false }
        return normalized(lastRequestedVersion) != version
    }

    public static func isShowingCompletion(job: ImportJob?, finishedID: UUID, detailID: UUID?) -> Bool {
        guard let job, job.phase == .completed, job.id == finishedID else { return false }
        return detailID == (job.isSharedAlbum ? job.albumID : job.id)
    }

    private static func normalized(_ version: String?) -> String? {
        guard let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
