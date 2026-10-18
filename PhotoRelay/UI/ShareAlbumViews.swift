import SwiftUI
import UIKit

/// The library separates owned exports from received albums while keeping the
/// same covers and detail navigation in both native segmented tabs.
struct ShareAlbumLibraryView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    @ObservedObject var importer: ImportController
    @Binding var selection: AlbumLibrarySection
    var onOpenSent: (UUID) -> Void
    var onOpenReceived: (UUID) -> Void
    @State private var deleting: ImportJob?
    private var receivedAlbums: [ImportJob] { importer.library.filter(\.isSharedAlbum) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            Picker(L10n.tr("相册类别"), selection: $selection) {
                Text(L10n.tr("我分享的")).tag(AlbumLibrarySection.sent)
                Text(L10n.tr("收到的")).tag(AlbumLibrarySection.received)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("albumLibrarySegments")
            if selection == .sent {
                if package.library.isEmpty {
                    ContentUnavailableView(L10n.tr("还没有分享相册"), systemImage: "photo.stack",
                        description: Text(L10n.tr("发送照片或视频后，相册会保存在这里。")))
                        .accessibilityIdentifier("sentAlbumEmptyState")
                } else {
                    PackageLibraryView(package: package, onOpen: onOpenSent)
                }
            } else if receivedAlbums.isEmpty {
                ContentUnavailableView(L10n.tr("还没有收到的相册"), systemImage: "tray",
                    description: Text(L10n.tr("打开朋友分享的相册后，会保存在这里。")))
                    .accessibilityIdentifier("receivedAlbumEmptyState")
            } else {
                ForEach(receivedAlbums) { job in
                    Button { onOpenReceived(job.albumID) } label: {
                        HStack(spacing: 16) {
                            ReceivedAlbumCover(controller: importer, job: job)
                                .frame(width: 80, height: 80)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job.displayTitle).font(.headline).foregroundStyle(RelayTheme.ink)
                                    .lineLimit(2)
                                Text(AlbumText.mediaSummary(job)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(.plain)
                    .disabled(importer.isBusy || importer.isPreparing || package.isBusy)
                    .accessibilityIdentifier("receivedAlbumRow-\(job.albumID)")
                    .contextMenu {
                        Button(L10n.tr("移除本地记录"), systemImage: "trash", role: .destructive) { deleting = job }
                    }
                }
            }
        }
        .alert(L10n.tr("移除这本分享相册？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("移除"), role: .destructive) {
                guard let job = deleting else { return }
                deleting = nil
                Task { _ = await importer.deleteAlbum(albumID: job.albumID) }
            }
            Button(L10n.tr("取消"), role: .cancel) { deleting = nil }
        } message: { Text(L10n.tr("移除本地记录和预览，原文件、系统相册及已保存的去重记录都会保留。")) }
    }
}

struct ReceivedAlbumDetailView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    var actionsDisabled: Bool
    var onRelink: () -> Void
    var onIssues: (IssueKind) -> Void
    var onClear: () -> Void
    var onShare: () -> Void
    var onDetails: () -> Void
    var onPreview: (ImportItem) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if controller.isPreparing {
                HStack(spacing: 12) { ProgressView(); Text(L10n.tr("正在读取文件…")) }
                    .padding(.vertical, 32).accessibilityIdentifier("importScanning")
            } else if let job = controller.job {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.isSharedAlbum ? job.displayTitle : job.source.name)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("albumTitle")
                    Text(AlbumDetailText.summary(media: AlbumText.mediaSummary(job),
                        dates: job.items.compactMap(\.creationDate),
                        senderName: job.isSharedAlbum ? job.album?.senderName : nil))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("albumSummary")
                }
                recoveryActions(job)
                LazyVGrid(columns: [GridItem(.adaptive(
                    minimum: dynamicTypeSize.isAccessibilitySize ? 160 : horizontalSizeClass == .regular ? 150 : 94,
                    maximum: 180), spacing: 8)], spacing: 8) {
                    ForEach(job.items) { item in
                        Button { onPreview(item) } label: {
                            ReceivedAssetThumbnail(controller: controller, activity: controller.activity,
                                jobID: job.id, item: item)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("previewReceivedAsset-\(item.id)")
                    }
                }
                .accessibilityIdentifier("receivedAlbumAssets")
            } else if controller.requiresReset {
                Text(L10n.tr(controller.message ?? "保存记录需要核对。"))
                    .font(.subheadline).foregroundStyle(RelayTheme.warning)
                Button(L10n.tr("清除损坏记录"), role: .destructive, action: onClear)
            } else {
                ContentUnavailableView(L10n.tr("尚未打开文件"), systemImage: "doc",
                    description: Text(L10n.tr("选择照片、视频或压缩包，保存到系统相册。")))
                if let message = controller.message {
                    Text(L10n.tr(message)).font(.footnote).foregroundStyle(RelayTheme.warning)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(controller.job?.isSharedAlbum == false ? "oneTimeImportDetail" : "receivedAlbumDetail")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let job = controller.job {
                    if controller.isBusy || job.phase == .paused {
                        NativeImportProgress(controller: controller, activity: controller.activity)
                        Button {
                            if controller.isBusy { controller.pause() } else { controller.start() }
                        } label: { Image(systemName: controller.isBusy ? "pause.fill" : "play.fill") }
                            .disabled(actionsDisabled || controller.isPreparing || (!controller.isBusy && !controller.canStart))
                            .accessibilityLabel(controller.isBusy ? L10n.tr("暂停保存") : L10n.tr("继续保存"))
                            .accessibilityIdentifier("nativeImportPauseResume")
                    }
                    Menu {
                        Button(L10n.tr("详细信息"), systemImage: "info.circle") { onDetails() }
                            .accessibilityIdentifier("receivedAlbumInfoButton")
                        Button(L10n.tr("保存设置"), systemImage: "slider.horizontal.3") { onDetails() }
                        Button(L10n.tr("移除当前记录"), systemImage: "trash", role: .destructive, action: onClear)
                            .disabled(actionsDisabled || controller.isBusy || controller.isPreparing)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(job.isSharedAlbum ? L10n.tr("相册选项") : L10n.tr("导入选项"))
                        .accessibilityIdentifier("receivedAlbumOptionsButton")
                    if job.isSharedAlbum {
                        // Forward the original archive without requiring any Photos writes.
                        // Keep this familiar entry visible during all album states.
                        Button {
                            if controller.needsRelink { onRelink() } else { onShare() }
                        } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(actionsDisabled || controller.isPreparing || controller.isBusy || !controller.canShareArchive)
                            .accessibilityLabel(L10n.tr("分享相册"))
                            .accessibilityIdentifier("receivedShareButton")
                    }
                }
            }
        }
    }

    @ViewBuilder private func recoveryActions(_ job: ImportJob) -> some View {
        if controller.needsRelink {
            Button(L10n.tr("重新连接原文件"), systemImage: "folder.badge.questionmark", action: onRelink)
                .disabled(actionsDisabled || controller.isBusy || controller.isPreparing)
                .accessibilityIdentifier("relinkSourceButton")
        }
        if job.uncertainCount > 0 {
            Button(L10n.tr("%@ 项待核对", String(job.uncertainCount)), systemImage: "questionmark.circle") { onIssues(.uncertain) }
                .foregroundStyle(RelayTheme.warning)
        }
        if job.failedCount > 0 {
            Button(L10n.tr("%@ 项未保存", String(job.failedCount)), systemImage: "exclamationmark.circle") { onIssues(.failed) }
                .foregroundStyle(RelayTheme.warning)
        }
        if let message = controller.message, !controller.isBusy,
           job.phase != .completed && (job.failedCount > 0 || job.uncertainCount > 0 || controller.requiresReset || !controller.canStart ||
               message == PhotoLibraryWriterError.permissionDenied.localizedDescription) {
            Text(L10n.tr(message)).font(.footnote).foregroundStyle(RelayTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !controller.isBusy, controller.message == PhotoLibraryWriterError.permissionDenied.localizedDescription {
            Button(L10n.tr("设置"), systemImage: "gearshape") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.footnote)
            .accessibilityIdentifier("albumPhotoAccessButton")
        }
    }
}

/// Installed on the outer ScrollView by ContentView. Its measured height is
/// removed from the scrollable safe area, including at accessibility text sizes.
struct ReceivedAlbumActionBar: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    var actionsDisabled: Bool
    var onRelink: () -> Void
    var onFinish: () -> Void

    var body: some View {
        if let job = controller.job {
            let action = AlbumDetailPolicy.primaryAction(for: job)
            VStack(spacing: 0) {
            Button {
                if action == .finish { onFinish() }
                else if controller.needsRelink { onRelink() }
                else { controller.start() }
            } label: {
                Label(L10n.tr(action.titleKey), systemImage: action == .finish ? "arrow.backward" : "square.and.arrow.down")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(AlbumBottomActionStyle())
            .disabled(actionsDisabled || controller.isPreparing || controller.isBusy || controller.requiresReset ||
                !AlbumDetailPolicy.canPerformPrimaryAction(for: job,
                    canStart: controller.canStart, needsRelink: controller.needsRelink))
            .accessibilityIdentifier(action == .finish ? "finishImportButton" : "importPrimaryButton")
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("albumBottomActionBar")
        }
    }
}

private struct AlbumBottomActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(isEnabled ? RelayTheme.onAccent : Color.secondary)
            .background(isEnabled ? RelayTheme.accent : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed && isEnabled ? 0.8 : 1)
    }
}

struct ReceivedAlbumDetailsSheet: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let job = controller.job {
                    Section(L10n.tr("详细信息")) {
                        LabeledContent(L10n.tr("相册名称"), value: job.displayTitle)
                        LabeledContent(L10n.tr("相册大小"), value: byteText(job.totalBytes))
                        if let date = AlbumDetailText.captureDates(job.items.compactMap(\.creationDate)) {
                            LabeledContent(L10n.tr("拍摄日期"), value: date)
                        }
                        if let sender = AlbumDetailText.sender(job.album?.senderName) {
                            Text(L10n.tr("来自 %@", sender))
                        }
                    }
                    Section(L10n.tr("同步记录")) {
                        Text(L10n.tr("%@ / %@ 项", String(job.savedCount), String(job.items.count)))
                            .accessibilityIdentifier("importSavedCount")
                        Text(L10n.tr("本次新增 %@ 项 · 已有 %@ 项", String(max(0, job.savedCount - controller.previouslySavedCount)), String(controller.previouslySavedCount)))
                            .accessibilityIdentifier("previouslySavedCount")
                    }
                    Section(L10n.tr("保存设置")) {
                        Picker(L10n.tr("保存间隔"), selection: $controller.delaySeconds) {
                            Text(L10n.tr("连续")).tag(0.0)
                            Text(L10n.tr("0.5 秒")).tag(0.5)
                            Text(L10n.tr("1 秒")).tag(1.0)
                        }.disabled(controller.isBusy || controller.isPreparing)
                        Text(L10n.tr("已确认保存的内容会跳过；暂停后可继续。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(L10n.tr("相册关联")) {
                        if job.isSharedAlbum && job.systemAlbumIdentifier != nil {
                            Label(L10n.tr("关联相册：Dropack · %@", job.displayTitle), systemImage: "photo.on.rectangle")
                        } else {
                            Label(L10n.tr("存入系统相册"), systemImage: "photo")
                                .accessibilityIdentifier("oneTimeImportDestination")
                        }
                        if job.albumLinkUnavailable == true {
                            Button(L10n.tr("允许完整访问以关联相册")) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("详细信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("完成")) { dismiss() }.accessibilityIdentifier("albumInfoDoneButton") } }
        }
        .tint(RelayTheme.accent)
        .accessibilityIdentifier("receivedAlbumDetailsSheet")
    }
}

/// Shared by sent and received detail headers; unknown capture dates and sender
/// labels are omitted rather than replaced with filesystem dates or made-up names.
enum AlbumDetailText {
    static func sender(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    static func captureDates(_ dates: [Date]) -> String? {
        guard let range = AlbumDetailPolicy.captureDateRange(dates) else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)
        let first = range.lowerBound.formatted(style)
        let last = range.upperBound.formatted(style)
        return first == last ? first : "\(first) – \(last)"
    }

    static func summary(media: String, dates: [Date], senderName: String?) -> String {
        var parts: [String] = []
        if let date = captureDates(dates) { parts.append(date) }
        if let sender = sender(senderName) { parts.append(L10n.tr("来自 %@", sender)) }
        parts.append(media)
        return parts.joined(separator: " · ")
    }
}

struct NativeImportProgress: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    @ObservedObject var activity: ImportActivity
    var body: some View {
        Group {
            if let job = controller.job {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(RelayTheme.accent.opacity(0.18), lineWidth: 2)
                        Circle().trim(from: 0, to: min(1, max(0, activity.currentFraction)))
                            .stroke(RelayTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 16, height: 16)
                    Text("\(job.savedCount)/\(job.items.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 58).lineLimit(1).minimumScaleFactor(0.6)
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.tr("%@，当前文件 %@%，已保存 %@ 项，共 %@ 项", L10n.tr(activity.currentStage), String(describing: Int(min(1, max(0, activity.currentFraction)) * 100)), String(describing: job.savedCount), String(describing: job.items.count)))
                    .accessibilityIdentifier("nativeImportProgress")
            }
        }
    }
}

struct ReceivedAlbumCover: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    let controller: ImportController
    let job: ImportJob
    var body: some View {
        Group {
            if job.items.count >= 4 {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow { thumbnail(0); thumbnail(1) }
                    GridRow { thumbnail(2); thumbnail(3) }
                }
            } else if let item = job.items.first {
                ReceivedAssetThumbnail(controller: controller, activity: controller.activity,
                    jobID: job.id, item: item, showsStatus: false, cornerRadius: 0)
            } else {
                RelayTheme.paleAccent.overlay { Image(systemName: "photo.stack").foregroundStyle(RelayTheme.accent) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
    }
    private func thumbnail(_ index: Int) -> some View {
        ReceivedAssetThumbnail(controller: controller, activity: controller.activity,
            jobID: job.id, item: job.items[index], showsStatus: false, cornerRadius: 0)
    }
}

/// Each visible cell owns its image. Only the active resource animates; a
/// progress update never replaces the grid or changes its geometry.
struct ReceivedAssetThumbnail: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    let controller: ImportController
    @ObservedObject var activity: ImportActivity
    let jobID: UUID
    let item: ImportItem
    var showsStatus = true
    var cornerRadius: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: UIImage?
    @State private var savedPulse = false

    private var current: Bool { controller.job?.id == jobID && activity.activePreview?.itemID == item.id }
    private var renderedImage: UIImage? {
        if current, let image = activity.activePreview?.image { return image }
        return thumbnail
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                RelayTheme.paleAccent
                if let image = renderedImage {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(savedPulse && !reduceMotion ? 0.90 : 1)
                        .opacity(savedPulse && !reduceMotion ? 0.7 : 1)
                } else {
                    Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
                        .font(.title2).foregroundStyle(RelayTheme.accent.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsStatus {
                    Group {
                        switch item.state {
                        case .saved:
                            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(RelayTheme.accent, .white)
                        case .failed, .uncertain:
                            Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(RelayTheme.warning, .white)
                        default:
                            if current {
                                Image(systemName: "arrow.down.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(RelayTheme.accent, .white)
                            }
                        }
                    }.padding(7)
                    if item.kind == .video || item.pairedVideo != nil {
                        Image(systemName: item.pairedVideo == nil ? "video.fill" : "livephoto")
                            .font(.caption2).foregroundStyle(.white).padding(7)
                            .background(.black.opacity(0.4), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(current ? RelayTheme.accent : .clear, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((item.relativePath as NSString).lastPathComponent)
        .accessibilityValue(item.state == .saved ? L10n.tr("已存入相册") : L10n.tr("待存入相册"))
        .accessibilityIdentifier("receivedThumbnail-\(item.id)")
        .task(id: "\(jobID)-\(item.id)-\(item.state.rawValue)") {
            if let url = await controller.loadThumbnail(jobID: jobID, itemID: item.id), !Task.isCancelled {
                thumbnail = UIImage(contentsOfFile: url.path)
            }
        }
        .onChange(of: item.state) { old, new in
            guard old != .saved, new == .saved, !reduceMotion else { return }
            savedPulse = true
            Task { @MainActor in
                await Task.yield()
                withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) { savedPulse = false }
            }
        }
        .onDisappear { thumbnail = nil }
    }
}

private enum AlbumText {
    static func mediaSummary(_ job: ImportJob) -> String {
        let photos = job.items.filter { $0.kind == .photo }.count
        let videos = job.items.count - photos
        if photos == 0 { return L10n.tr("%@ 个视频", String(describing: videos)) }
        if videos == 0 { return L10n.tr("%@ 张照片", String(describing: photos)) }
        return L10n.tr("%@ 张照片 · %@ 个视频", String(describing: photos), String(describing: videos))
    }
}
