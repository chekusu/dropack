import SwiftUI

/// Display-only interpretation of one resource's progress. The resource percentage
/// must never be presented as a byte-weighted percentage for the whole album.
struct PackageProgressPresentation: Equatable {
    enum State: Equatable { case running, pausing, paused, ready, failed }

    let state: State
    let completedCount: Int
    let totalCount: Int
    let stage: String
    let name: String
    let resourceFraction: Double?
    let readBytes: UInt64?

    init(snapshot: PackageActivitySnapshot, isBusy: Bool, pauseRequested: Bool, phase: PackagePhase) {
        completedCount = snapshot.completedCount
        totalCount = snapshot.totalCount
        if phase == .ready { state = .ready }
        else if isBusy { state = pauseRequested ? .pausing : .running }
        else { state = phase == .failed ? .failed : .paused }

        let hasLiveResource = (state == .running || state == .pausing)
            && (!snapshot.name.isEmpty || snapshot.readBytes != nil)
        name = hasLiveResource ? snapshot.name : ""
        readBytes = hasLiveResource ? snapshot.readBytes : nil
        resourceFraction = hasLiveResource && snapshot.readBytes == nil ? snapshot.fraction : nil
        switch state {
        case .running: stage = snapshot.stage.isEmpty ? "准备打包" : snapshot.stage
        case .pausing: stage = "暂停中"
        case .paused: stage = "已暂停"
        case .ready: stage = "已就绪"
        case .failed: stage = "需处理"
        }
    }

    var percentage: Int? { resourceFraction.map { Int(($0 * 100).rounded(.down)) } }
    var percentageText: String? { percentage.map { "\($0)%" } }
    var readBytesText: String? { readBytes.map(TransferByteCountText.string) }
    var resourceValueText: String? { readBytesText ?? percentageText }
    var primaryValueText: String { resourceValueText ?? countText }
    var resourceAccessibilityLabel: String {
        L10n.tr(readBytes == nil ? "当前文件处理进度" : "读取当前文件")
    }
    var countText: String { "\(completedCount) / \(totalCount)" }
    var compactText: String { resourceValueText ?? "\(completedCount)/\(totalCount)" }
    var committedFraction: Double { totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0 }
    /// Preparation/final verification has no byte progress. Use the native spinner
    /// instead of implying that zero (or all completed items) is a total percentage.
    var isIndeterminate: Bool { state == .running && resourceFraction == nil }
    var barFraction: Double { resourceFraction ?? committedFraction }
    var localizedStage: String { L10n.tr(stage) }
    var countAccessibilityLabel: String {
        L10n.tr("已打包 %@ / %@ 项", String(completedCount), String(totalCount))
    }
    var accessibilityValue: String {
        [localizedStage, name.isEmpty ? nil : name,
         resourceValueText.map { "\(resourceAccessibilityLabel) \($0)" },
         countAccessibilityLabel].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The navigation item observes only the lightweight activity, not the entire
/// album. A one-video package shows its current resource percentage, not only 0/1.
struct NativePackageProgress: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var activity: PackageActivity
    var isBusy = true
    var pauseRequested = false
    var phase: PackagePhase = .packing
    let onDetails: () -> Void

    var body: some View {
        let presentation = PackageProgressPresentation(snapshot: activity.snapshot, isBusy: isBusy,
                                                       pauseRequested: pauseRequested, phase: phase)
        Button(action: onDetails) {
            Text(presentation.compactText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 58)
        }
        .accessibilityLabel(L10n.tr("打包进度"))
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(L10n.tr("查看任务详情"))
        .accessibilityIdentifier("nativePackageProgress")
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

/// Mounted inside the sent album regardless of Live Activity availability. Only
/// this small subtree subscribes to resource callbacks, leaving the grid intact.
struct PackageAlbumProgress: View {
    @ObservedObject var activity: PackageActivity
    var isBusy: Bool
    var pauseRequested: Bool
    var phase: PackagePhase

    var body: some View {
        PackageProgressReadout(presentation: .init(snapshot: activity.snapshot, isBusy: isBusy,
            pauseRequested: pauseRequested, phase: phase))
    }
}

/// A fixed two-line footprint prevents filename, count and percentage updates
/// from moving the album grid. It also renders historical paused journals without
/// subscribing to an unrelated active album's progress.
struct PackageProgressReadout: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    let presentation: PackageProgressPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(presentation.localizedStage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(presentation.state == .failed ? RelayTheme.warning : RelayTheme.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("albumPackageProgressStage")
                Spacer(minLength: 4)
                Text(presentation.primaryValueText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(RelayTheme.accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel(presentation.resourceValueText == nil
                        ? presentation.countAccessibilityLabel : presentation.resourceAccessibilityLabel)
                    .accessibilityValue(presentation.primaryValueText)
                    .accessibilityIdentifier("albumPackageProgressValue")
            }
            ZStack(alignment: .leading) {
                if presentation.isIndeterminate {
                    ProgressView().controlSize(.mini)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView(value: presentation.barFraction)
                        .progressViewStyle(.linear)
                }
            }
            .tint(RelayTheme.accent)
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                Text(presentation.name.isEmpty ? L10n.tr("打包进度") : presentation.name)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("albumPackageProgressFile")
                Spacer(minLength: 4)
                Text(presentation.resourceValueText == nil ? " " : presentation.countText)
                    .monospacedDigit().lineLimit(1)
                    .accessibilityLabel(presentation.countAccessibilityLabel)
                    .accessibilityIdentifier("albumPackageProgressCount")
                    .accessibilityHidden(presentation.resourceValueText == nil)
            }
            .font(.caption).foregroundStyle(RelayTheme.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("albumPackageProgress")
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}
