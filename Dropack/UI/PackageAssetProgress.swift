import SwiftUI

/// Original availability and durable ZIP packaging are separate facts. A
/// completed cloud download does not mean the original has been captured, and
/// neither operation earns the final packaged checkmark.
struct PackageAssetProgressPresentation: Equatable {
    enum State: Equatable { case waiting, running, pausing, paused, completed }
    let original: PackageOriginalProgress
    let state: State
    let fraction: Double?
    let stage: String

    init(snapshot: PackageActivitySnapshot, packageID: UUID, asset: PackageAsset,
         isBusy: Bool, pauseRequested: Bool, phase: PackagePhase) {
        let matchesPackage = snapshot.packageID == packageID
        let isCurrent = matchesPackage && snapshot.assetID == asset.id
        let completed = asset.isCompleted || (matchesPackage && snapshot.completedAssetIDs.contains(asset.id))
        // A captured picker resource is app-owned and durable. An ordinary file
        // bookmark can still point into iCloud or another provider: it proves no
        // local availability by itself.
        let capturedOriginal = asset.pickerResourcePending == false && asset.fileSource != nil
        if completed || capturedOriginal {
            original = .ready
        } else if matchesPackage, let reported = snapshot.originalProgressByAssetID[asset.id] {
            // Even a ready staging file can be removed during pause/rollback.
            // Once idle, only the durable branches above prove original readiness.
            // While cancellation is still unwinding, keep a confirmed ready file
            // but never leave a provisional download percentage on the thumbnail.
            original = !isBusy || (pauseRequested && reported.state != .ready) ? .unknown : reported
        } else {
            original = .unknown
        }

        if completed {
            state = .completed; fraction = nil; stage = "已打包"
        } else if isCurrent && isBusy, let packing = Self.validFraction(snapshot.packingFraction) {
            state = pauseRequested ? .pausing : .running
            fraction = pauseRequested ? nil : packing
            stage = pauseRequested ? "暂停中" : "正在打包"
        } else {
            state = !isBusy && phase == .paused ? .paused : .waiting
            fraction = nil
            stage = state == .paused ? "已暂停" : "等待打包"
        }
    }

    var originalFraction: Double? {
        guard original.state == .preparing || original.state == .downloading else { return nil }
        return Self.validFraction(original.fraction)
    }
    var originalPercentage: Int? { originalFraction.map { Int(($0 * 100).rounded(.down)) } }
    var originalUsesCloud: Bool { original.state == .downloading && original.cloudConfirmed }
    var originalStage: String {
        switch original.state {
        case .unknown: return "原片状态待确认"
        case .preparing: return "正在准备原片"
        case .downloading: return original.cloudConfirmed ? "正在从 iCloud 下载" : "正在准备原片"
        case .ready: return "原片已就绪"
        }
    }
    var originalAccessibilityValue: String {
        [L10n.tr(originalStage), originalPercentage.map { "\($0)%" }].compactMap { $0 }.joined(separator: ", ")
    }
    var percentage: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
    var accessibilityValue: String {
        [L10n.tr(stage), percentage.map { "\($0)%" }].compactMap { $0 }.joined(separator: ", ")
    }

    private static func validFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, min(1, value))
    }
}

/// Only this small pair of indicators observes frequent callbacks. The decoded
/// thumbnail and its grid keep their identity during download and packaging.
struct PackageAssetProgressBadge: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var activity: PackageActivity
    let packageID: UUID
    let asset: PackageAsset
    let isBusy: Bool
    let pauseRequested: Bool
    let phase: PackagePhase
    var showsPackingIndicator = true

    var body: some View {
        let presentation = PackageAssetProgressPresentation(snapshot: activity.snapshot,
            packageID: packageID, asset: asset, isBusy: isBusy,
            pauseRequested: pauseRequested, phase: phase)
        HStack(spacing: 4) {
            if presentation.originalUsesCloud {
                originalIndicator(presentation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([asset.title, L10n.tr("原片准备进度")].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityValue(presentation.originalAccessibilityValue)
                    .accessibilityIdentifier("packageOriginalProgress-\(asset.id)")
            }
            if showsPackingIndicator {
                packingIndicator(presentation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([asset.title, L10n.tr("打包进度")].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityValue(presentation.accessibilityValue)
                    .accessibilityIdentifier("packagePackingProgress-\(asset.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packageAssetProgress-\(asset.id)")
        .allowsHitTesting(false)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func originalIndicator(_ presentation: PackageAssetProgressPresentation) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.72))
            progressRing(fraction: presentation.originalFraction, percentage: presentation.originalPercentage)
        }
        .frame(width: 32, height: 32)
        .overlay(alignment: .bottomLeading) {
            if presentation.originalUsesCloud {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(.black.opacity(0.9), in: Circle())
                    .offset(x: -2, y: 2)
            }
        }
    }

    private func packingIndicator(_ presentation: PackageAssetProgressPresentation) -> some View {
        ZStack {
            Circle().fill(.black.opacity(presentation.state == .waiting ? 0.45 : 0.72))
            switch presentation.state {
            case .completed:
                Circle().fill(RelayTheme.accent)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RelayTheme.onAccent)
            case .waiting:
                Circle().stroke(.white.opacity(0.35), lineWidth: 1.5).padding(3)
                Image(systemName: "shippingbox").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            case .paused, .pausing:
                Circle().stroke(.white.opacity(0.65), lineWidth: 1.5).padding(3)
                Image(systemName: "pause.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            case .running:
                progressRing(fraction: presentation.fraction, percentage: presentation.percentage)
            }
        }
        .frame(width: 32, height: 32)
    }

    private func progressRing(fraction: Double?, percentage: Int?) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5).padding(3)
            if let fraction, let percentage {
                Circle().trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(3)
                Text("\(percentage)%")
                    .font(.system(size: 8, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                // A source read count without total size cannot become a ratio.
                ProgressView().controlSize(.mini).tint(.white)
            }
        }
    }
}
