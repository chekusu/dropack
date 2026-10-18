import SwiftUI
import UIKit

/// This small subtree alone observes per-resource updates. Its fixed content
/// structure and predecoded cover never invalidate the album grid or navigation.
struct PackageTaskBanner: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    @ObservedObject var activity: PackageActivity
    var canResume: Bool
    var onPause: () -> Void
    var onResume: () -> Void
    var onDetails: () -> Void
    /// Prepared once by the host when the job changes, never decoded on a tick.
    var coverImage: UIImage? = nil

    private var progress: PackageActivitySnapshot { activity.snapshot }
    /// A new selection can be preparing while the previous job is still retained
    /// for recovery. Do not label the new operation with that older album's name.
    private var belongsToCurrentJob: Bool {
        !package.isBusy || (progress.packageID != nil && progress.packageID == package.job?.id)
    }
    private var job: PackageJob? { belongsToCurrentJob ? package.job : nil }
    private var isPausing: Bool { package.isPauseRequested }
    private var title: String {
        job?.displayTitle ?? L10n.tr(package.requiresReset ? "打包记录需要处理" : "准备分享相册")
    }
    private var presentation: PackageProgressPresentation {
        .init(snapshot: progress, isBusy: package.isBusy, pauseRequested: isPausing,
              phase: job?.phase ?? (package.requiresReset ? .failed : .preparing))
    }
    private var status: String {
        let value = presentation.resourceValueText.map { " · \($0)" } ?? ""
        return "\(presentation.localizedStage)\(value) · \(presentation.countText)"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Navigation and control are siblings. Tapping pause never opens an
            // album; opening the album never resumes or refreshes its package.
            Button(action: onDetails) {
                HStack(spacing: 12) {
                    PackageTaskCover(image: belongsToCurrentJob ? coverImage : nil)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RelayTheme.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier("packageTaskAlbumTitle")
                        Text(status)
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(presentation.state == .failed ? RelayTheme.warning : RelayTheme.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .accessibilityLabel(presentation.accessibilityValue)
                            .accessibilityIdentifier("packageTaskStage")
                        Group {
                            if presentation.isIndeterminate {
                                ProgressView().controlSize(.mini)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ProgressView(value: presentation.barFraction).progressViewStyle(.linear)
                            }
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("packageTaskProgress")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("分享相册"))
            .accessibilityHint(L10n.tr("查看任务详情"))
            .accessibilityIdentifier("packageTaskDetailsButton")

            Group {
                if package.canPause || (package.isBusy && isPausing) {
                    Button(action: onPause) {
                        controlText(isPausing ? "正在暂停" : "暂停打包")
                    }
                    .disabled(!package.canPause || isPausing)
                    .accessibilityIdentifier("pausePackageButton")
                } else if package.canResume {
                    Button(action: onResume) { controlText("继续打包") }
                        .disabled(!canResume)
                        .accessibilityIdentifier("resumePackageButton")
                } else if !package.isBusy {
                    // Permission / damaged-record failures need the album's
                    // recovery action, and must never disappear behind a dismiss.
                    Button(action: onDetails) { controlText("详细信息") }
                        .accessibilityIdentifier("recoverPackageTaskButton")
                }
            }
        }
        .buttonStyle(.plain)
        .tint(RelayTheme.accent)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 680, minHeight: 88, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(RelayTheme.accent.opacity(0.16), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packageTaskBanner")
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func controlText(_ key: String) -> some View {
        Text(L10n.tr(key))
            .font(.caption.weight(.semibold))
            .foregroundStyle(RelayTheme.accent)
            .multilineTextAlignment(.center)
            .lineLimit(2).minimumScaleFactor(0.75)
            .frame(width: 80)
            .frame(minHeight: 44)
            .background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }
}

/// The back card is decorative; only supplied photo pixels appear as a photo.
private struct PackageTaskCover: View {
    var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(RelayTheme.accent.opacity(0.16))
                .frame(width: 40, height: 40)
                .rotationEffect(.degrees(7))
                .offset(x: 3, y: -3)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        RelayTheme.surface
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(RelayTheme.accent)
                    }
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(RelayTheme.accent.opacity(0.14), lineWidth: 0.5)
            }
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }
}

/// The parent owns presentation/dismissal; only this sheet observes live progress.
struct PackageTaskDetails: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    @ObservedObject var activity: PackageActivity
    var pauseRequested: Bool
    var shareResult: String?
    var onDismiss: () -> Void

    private var progress: PackageActivitySnapshot { activity.snapshot }
    private var message: String? { shareResult ?? package.message }
    private var isPausing: Bool { pauseRequested || package.isPauseRequested }
    private var presentation: PackageProgressPresentation {
        .init(snapshot: progress, isBusy: package.isBusy, pauseRequested: isPausing,
              phase: package.job?.phase ?? .failed)
    }
    private var status: String {
        if isPausing && package.isBusy { return L10n.tr("正在安全暂停…") }
        if package.isBusy { return progress.stage.isEmpty ? L10n.tr("正在准备照片包…") : progress.stage }
        if package.archiveURL != nil { return shareResult ?? L10n.tr("照片包已就绪，可以分享了") }
        return message ?? L10n.tr("进度已保留，随时继续")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(L10n.tr("照片打包"), systemImage: "shippingbox")
                        .font(.title2.weight(.semibold))
                    Text(L10n.tr("已打包 %@ / %@ 项", String(describing: progress.completedCount), String(describing: progress.totalCount)))
                        .font(.headline).monospacedDigit()
                    Text(L10n.tr(status)).fixedSize(horizontal: false, vertical: true)
                    if let message, message != status { Text(L10n.tr(message)) }
                    PackageProgressReadout(presentation: presentation)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RelayTheme.background)
            .navigationTitle(L10n.tr("任务详情")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成"), action: onDismiss)
                        .accessibilityIdentifier("dismissPackageDetailsButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("packageTaskDetails")
    }
}
