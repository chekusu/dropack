import SwiftUI
import UIKit

/// The caller supplies navigation and scrolling. Library updates are infrequent;
/// per-resource packaging progress remains isolated in its own observed subtree.
struct PackageLibraryView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    var onOpen: (UUID) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if package.library.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("还没有发送的相册")).font(.title3.weight(.semibold))
                    Text(L10n.tr("选择照片或文件后，就会保存在这里。"))
                        .font(.subheadline).foregroundStyle(RelayTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityIdentifier("packageLibraryEmpty")
            } else {
                ForEach(package.library) { entry in
                    Button { onOpen(entry.id) } label: {
                        PackageLibraryRow(package: package, entry: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PackageLibraryText.accessibilitySummary(entry))
                    .accessibilityHint(L10n.tr("查看分享相册"))
                    .accessibilityIdentifier("packageRow-\(entry.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("packageLibrary")
    }
}

private struct PackageLibraryRow: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    var entry: PackageLibraryEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            PackageCoverView(package: package, entry: entry)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? 64 : 80,
                       height: dynamicTypeSize.isAccessibilitySize ? 64 : 80)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.job.displayTitle)
                    .font(.headline).foregroundStyle(RelayTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PackageLibraryText.mediaSummary(entry))
                    .font(.caption).foregroundStyle(RelayTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadata }
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RelayTheme.secondary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var metadata: some View {
        Text(PackageLibraryText.status(entry.phase))
            .foregroundStyle(entry.phase == .failed ? RelayTheme.warning : RelayTheme.accent)
        if entry.bytes > 0 {
            Text(PackageLibraryText.size(entry)).foregroundStyle(RelayTheme.secondary)
        }
    }
}

/// Displays only the requested package. Opening or inspecting another package
/// never activates it, resumes it, or changes the current packaging operation.
struct PackageLibraryDetailView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    var packageID: UUID
    var onShare: (PackageFileFormat) -> Void
    var onResume: () -> Void
    /// The parent owns deletion confirmation and the resulting navigation.
    var onDelete: () -> Void
    var onRename: () -> Void
    var onReselect: () -> Void
    var onDetails: () -> Void
    var onUpdated: (UUID) -> Void
    var onPreview: (UUID, PackageAsset) -> Void
    var actionsDisabled: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSelecting = false
    @State private var selectedAssetIDs = Set<String>()
    @State private var confirmingRemoval = false
    @State private var activeEditSheet: AlbumEditSheet?
    @State private var pendingAddSource: SendSourceChoice?
    @State private var pendingPhotoSelection: PhotoPickerSelection?
    @State private var pendingFileSources: [PendingSource] = []
    @State private var editSheetDismissed = true
    @State private var mutating = false
    @State private var editMessage: String?

    private var entry: PackageLibraryEntry? {
        if let unavailable = package.library.first(where: { $0.id == packageID && $0.issue != nil }) {
            return unavailable
        }
        if let job = package.job, job.id == packageID { return PackageLibraryEntry(job: job) }
        return package.library.first { $0.id == packageID }
    }
    private var disabled: Bool { actionsDisabled || package.isBusy || mutating }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let entry {
                header(entry)
                if PackageAlbumEditingPresentation.canResume(entry.phase), package.job?.id != entry.id, entry.issue == nil {
                    Button(L10n.tr("继续打包"), action: onResume)
                        .buttonStyle(.bordered)
                        .disabled(disabled)
                        .accessibilityIdentifier("libraryResumeButton")
                }
                if let message = editMessage ?? entry.issue ?? (entry.phase == .failed ? entry.job.lastMessage : nil) {
                    Text(L10n.tr(message))
                        .font(.footnote).foregroundStyle(RelayTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("packageLibraryError")
                }
                if package.job?.id == packageID, package.needsPhotoReselection {
                    Button(package.canReselectPhotos ? L10n.tr("重新选择未读完的照片") : L10n.tr("重新创建分享相册"), systemImage: "photo.on.rectangle", action: onReselect)
                        .disabled(actionsDisabled)
                }
                if entry.assets.isEmpty {
                    ContentUnavailableView(L10n.tr("还没有照片或视频"), systemImage: "photo.on.rectangle",
                        description: Text(L10n.tr("点击右上角添加。")))
                        .accessibilityIdentifier("emptySharedAlbum")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 160 : horizontalSizeClass == .regular ? 150 : 94,
                                                      maximum: 180), spacing: 8)], spacing: 8) {
                    ForEach(entry.assets) { asset in
                        if isSelecting {
                            Button { toggleSelection(asset.id) } label: {
                                PackageAssetThumbnail(package: package, packageID: entry.id, asset: asset)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 25, weight: .semibold))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(selectedAssetIDs.contains(asset.id) ? RelayTheme.accent : .white,
                                                             Color.black.opacity(0.65))
                                            .padding(7)
                                            .accessibilityHidden(true)
                                    }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .disabled(disabled)
                            .accessibilityAddTraits(selectedAssetIDs.contains(asset.id) ? .isSelected : [])
                            .accessibilityIdentifier("selectAlbumAsset-\(asset.id)")
                        } else {
                            Button { onPreview(entry.id, asset) } label: {
                                PackageAssetThumbnail(package: package, packageID: entry.id, asset: asset,
                                    showsPackagingProgress: entry.phase != .draft, phase: entry.phase,
                                    packagingRequested: entry.job.packagingRequested != false)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("previewAlbumAsset-\(asset.id)")
                        }
                    }
                }
                .accessibilityIdentifier("packageLibraryAssets")
            } else {
                Text(L10n.tr("分享相册已移除"))
                    .font(.title3.weight(.semibold)).foregroundStyle(RelayTheme.secondary)
                    .padding(.vertical, 20)
                    .accessibilityIdentifier("packageLibraryMissing")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packageLibraryDetail-\(packageID.uuidString)")
        .sheet(item: $activeEditSheet, onDismiss: didDismissEditSheet) { sheet in
            Group {
                switch sheet {
                case .sources:
                    SendSourceSheet { choice in
                        pendingAddSource = choice
                        activeEditSheet = nil
                    }
                case .photos:
                    PhotoPicker { selection, error in
                        pendingPhotoSelection = selection.isEmpty ? nil : selection
                        if let error { editMessage = error }
                        activeEditSheet = nil
                    }.ignoresSafeArea()
                case .files:
                    SendSourcePicker(onSelect: { urls in
                        pendingFileSources = urls.map { PendingSource(url: $0) }
                        activeEditSheet = nil
                    }, onCancel: { activeEditSheet = nil }).ignoresSafeArea()
                }
            }
            .onAppear { editSheetDismissed = false }
        }
        .alert(L10n.tr("从此相册移除 %@ 项？", String(selectedAssetIDs.count)), isPresented: $confirmingRemoval) {
            Button(L10n.tr("从相册移除"), role: .destructive, action: removeSelectedAssets)
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("只从这个分享相册及关联的系统相册中移除，不会删除系统照片。"))
        }
        .onChange(of: packageID) { _, _ in
            isSelecting = false
            selectedAssetIDs.removeAll()
        }
        .onChange(of: entry?.assets.map(\.id) ?? []) { _, ids in
            selectedAssetIDs.formIntersection(ids)
        }
        .onChange(of: pendingPhotoSelection?.count) { _, _ in consumeAddSelection() }
        .onChange(of: pendingFileSources.map(\.id)) { _, _ in consumeAddSelection() }
    }

    private func header(_ entry: PackageLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.job.displayTitle).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("albumTitle")
            Text(AlbumDetailText.summary(media: PackageLibraryText.mediaSummary(entry),
                dates: entry.assets.compactMap { $0.captureDate ?? $0.manifestItem?.creationDate },
                senderName: entry.job.album?.senderName))
                .font(.subheadline).foregroundStyle(RelayTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("albumSummary")
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button(L10n.tr(selectedAssetIDs.count == entry.assets.count ? "取消全选" : "全选")) {
                        if selectedAssetIDs.count == entry.assets.count { selectedAssetIDs.removeAll() }
                        else { selectedAssetIDs = Set(entry.assets.map(\.id)) }
                    }
                    .disabled(disabled || entry.assets.isEmpty)
                    .accessibilityIdentifier("selectAllAlbumAssets")
                    Button(L10n.tr("移除"), role: .destructive) { confirmingRemoval = true }
                        .disabled(disabled || selectedAssetIDs.isEmpty)
                        .accessibilityIdentifier("removeSelectedAlbumAssets")
                    Button(L10n.tr("完成")) { isSelecting = false; selectedAssetIDs.removeAll() }
                        .disabled(mutating)
                        .accessibilityIdentifier("finishSelectingAlbumAssets")
                } else {
                    Button { editMessage = nil; activeEditSheet = .sources } label: { Image(systemName: "plus") }
                        .disabled(disabled || entry.issue != nil)
                        .accessibilityLabel(L10n.tr("添加到相册"))
                        .accessibilityIdentifier("addToAlbumButton")
                    Menu {
                        Button(L10n.tr("选择项目"), systemImage: "checkmark.circle") {
                            selectedAssetIDs.removeAll(); isSelecting = true
                        }.disabled(disabled || entry.assets.isEmpty || entry.issue != nil)
                            .accessibilityIdentifier("selectAlbumAssetsButton")
                        Button(L10n.tr("详细信息"), systemImage: "info.circle") { onDetails() }
                            .accessibilityIdentifier("sentAlbumInfoButton")
                        Button(L10n.tr("重命名"), systemImage: "pencil", action: onRename)
                            .disabled(disabled)
                        Button(L10n.tr("导出普通 ZIP"), systemImage: "doc.zipper") { onShare(.zip) }
                            .disabled(!PackageAlbumEditingPresentation.canShare(assetCount: entry.totalCount,
                                hasIssue: entry.issue != nil, isBusy: disabled))
                        Button(L10n.tr("删除本地分享包"), systemImage: "trash", role: .destructive, action: onDelete)
                            .disabled(disabled)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(L10n.tr("相册选项"))
                    .accessibilityIdentifier("albumOptionsButton")
                    Button { onShare(.dropack) } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(!PackageAlbumEditingPresentation.canShare(assetCount: entry.totalCount,
                            hasIssue: entry.issue != nil, isBusy: disabled))
                        .accessibilityLabel(L10n.tr("分享相册"))
                        .accessibilityIdentifier("libraryShareButton")
                }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedAssetIDs.contains(id) { selectedAssetIDs.remove(id) }
        else { selectedAssetIDs.insert(id) }
    }

    private func didDismissEditSheet() {
        editSheetDismissed = true
        if let source = pendingAddSource {
            pendingAddSource = nil
            guard !disabled else { return }
            activeEditSheet = source == .photos ? .photos : .files
            return
        }
        consumeAddSelection()
    }

    /// Provider callbacks and UIKit sheet dismissal can arrive in either order.
    /// Start an edit only after both have completed, retaining file access until
    /// the service has saved the new album's durable bookmarks or captured data.
    private func consumeAddSelection() {
        guard editSheetDismissed, activeEditSheet == nil, !disabled else { return }
        let targetID = packageID
        if let selection = pendingPhotoSelection {
            pendingPhotoSelection = nil
            mutating = true; editMessage = nil
            Task {
                defer { mutating = false }
                let updated = await package.add(selection: selection, to: targetID, onCreated: onUpdated)
                if updated == nil { editMessage = package.message ?? "未能更新相册，请重试。" }
            }
        } else if !pendingFileSources.isEmpty {
            let sources = pendingFileSources
            pendingFileSources = []
            mutating = true; editMessage = nil
            Task {
                defer { mutating = false; sources.forEach { $0.releaseScope() } }
                let updated = await package.add(fileURLs: sources.map(\.url), to: targetID, onCreated: onUpdated)
                if updated == nil { editMessage = package.message ?? "未能更新相册，请重试。" }
            }
        }
    }

    private func removeSelectedAssets() {
        guard !disabled, let entry else { return }
        let ids = entry.assets.map(\.id).filter { selectedAssetIDs.contains($0) }
        guard !ids.isEmpty else { return }
        let targetID = packageID
        mutating = true; editMessage = nil
        Task {
            defer { mutating = false }
            if await package.remove(assetIDs: ids, from: targetID, onCreated: onUpdated) != nil {
                isSelecting = false; selectedAssetIDs.removeAll()
            } else { editMessage = package.message ?? "未能更新相册，请重试。" }
        }
    }

    private enum AlbumEditSheet: String, Identifiable {
        case sources, photos, files
        var id: String { rawValue }
    }

}

struct PackageAlbumDetailsSheet: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    let packageID: UUID
    @Environment(\.dismiss) private var dismiss

    private var entry: PackageLibraryEntry? {
        if let job = package.job, job.id == packageID { return PackageLibraryEntry(job: job) }
        return package.library.first { $0.id == packageID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let entry {
                Section(L10n.tr("详细信息")) {
                    LabeledContent(L10n.tr("相册名称"), value: entry.job.displayTitle)
                    Text(PackageLibraryText.mediaSummary(entry))
                    LabeledContent(L10n.tr("相册大小"), value: PackageLibraryText.size(entry))
                    if let dates = AlbumDetailText.captureDates(entry.assets.compactMap({ $0.captureDate ?? $0.manifestItem?.creationDate })) {
                        LabeledContent(L10n.tr("拍摄日期"), value: dates)
                    }
                    if let sender = AlbumDetailText.sender(entry.job.album?.senderName) {
                        Text(L10n.tr("来自 %@", sender))
                    }
                }
                Section(L10n.tr(entry.phase == .draft ? "分享相册" : "打包进度")) {
                    Text(PackageLibraryText.status(entry.phase))
                        .accessibilityIdentifier("albumPackageStatus")
                    if entry.phase == .draft { Text(L10n.tr("分享时打包")) }
                    else { Text(L10n.tr("%@ / %@ 项", String(entry.completedCount), String(entry.totalCount))) }
                    if (entry.job.addedAssetCount ?? 0) > 0 || (entry.job.removedAssetCount ?? 0) > 0 {
                        Text(L10n.tr("新增 %@ 项 · 移除 %@ 项", String(entry.job.addedAssetCount ?? 0), String(entry.job.removedAssetCount ?? 0)))
                    }
                }
                if entry.job.linkedPhotosAlbumIdentifier != nil {
                    Section(L10n.tr("相册关联")) {
                        Label(L10n.tr("关联相册：Dropack · %@", entry.job.displayTitle), systemImage: "photo.on.rectangle")
                    }
                }
                if let message = entry.issue ?? entry.job.lastMessage, entry.phase == .failed {
                    Section(L10n.tr("需处理")) { Text(L10n.tr(message)).foregroundStyle(RelayTheme.warning) }
                }
                }
            }
            .navigationTitle(L10n.tr("详细信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成")) { dismiss() }.accessibilityIdentifier("albumInfoDoneButton")
                }
            }
        }
        .tint(RelayTheme.accent)
        .accessibilityIdentifier("sentAlbumDetailsSheet")
    }
}

/// A square made from one real thumbnail, or four when available. It can also be
/// placed on the send page; no parent state is needed for image loading.
struct PackageCoverView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    var entry: PackageLibraryEntry

    var body: some View {
        Group {
            if entry.assets.count >= 4 {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        thumbnail(entry.assets[0])
                        thumbnail(entry.assets[1])
                    }
                    GridRow {
                        thumbnail(entry.assets[2])
                        thumbnail(entry.assets[3])
                    }
                }
            } else if let asset = entry.assets.first {
                thumbnail(asset)
            } else {
                Color.clear.overlay {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2).foregroundStyle(RelayTheme.accent)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(RelayTheme.paleAccent)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }

    private func thumbnail(_ asset: PackageAsset) -> some View {
        PackageAssetThumbnail(package: package, packageID: entry.id, asset: asset,
                              showsMediaBadge: false, cornerRadius: 0)
    }
}

/// Each visible cell owns its small JPEG. `loadThumbnail` bounds generation;
/// UIImage never receives a full-size original photo or video resource here.
struct PackageAssetThumbnail: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var package: PackageController
    var packageID: UUID
    var asset: PackageAsset
    var showsMediaBadge = true
    var cornerRadius: CGFloat = 14
    var showsPackagingProgress = false
    var phase: PackagePhase = .ready
    var packagingRequested = true
    @State private var image: UIImage?
    @State private var displayedIdentity: String?

    private var identity: String { "\(packageID.uuidString)/\(asset.id)" }
    private var loadIdentity: String {
        "\(identity)/\(asset.isCompleted)/\(package.isBusy && package.job?.id == packageID)"
    }
    private var isVideo: Bool {
        asset.kind == .video || (asset.manifestItem?.photoPath == nil && asset.manifestItem?.videoPath != nil)
    }
    private var isLivePhoto: Bool { asset.manifestItem?.isLivePhoto == true }
    private var symbol: String { isLivePhoto ? "livephoto" : (isVideo ? "video.fill" : "photo.fill") }
    private var kindName: String { isLivePhoto ? L10n.tr("实况照片") : (isVideo ? L10n.tr("视频") : L10n.tr("照片")) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                RelayTheme.paleAccent
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: min(geometry.size.width * 0.28, 30), weight: .regular))
                        .foregroundStyle(RelayTheme.accent.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsMediaBadge {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(7)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .accessibilityHidden(true)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if showsPackagingProgress {
                PackageAssetProgressBadge(activity: package.activity, packageID: packageID,
                    asset: asset, isBusy: package.isBusy && package.job?.id == packageID,
                    pauseRequested: package.isPauseRequested, phase: phase,
                    showsPackingIndicator: packagingRequested)
                    .padding(6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(asset.title.map { "\(kindName)，\($0)" } ?? kindName)
        .accessibilityValue(thumbnailAccessibilityStatus)
        .accessibilityIdentifier("packageThumbnail-\(asset.id)")
        .task(id: loadIdentity) { await loadPreview() }
        .onDisappear { image = nil }
    }

    // Keep packaging and preview readiness independently observable. Reuse the
    // existing localized states, while retaining the stable thumbnail identifier.
    private var thumbnailAccessibilityStatus: String {
        let packaging = L10n.tr(asset.isCompleted ? "已就绪" : "准备中")
        let preview = L10n.tr(image == nil ? "准备中" : "已就绪")
        if !packagingRequested || phase == .draft { return L10n.tr("照片预览") + ": " + preview }
        return packaging + " · " + L10n.tr("照片预览") + ": " + preview
    }

    @MainActor private func loadPreview() async {
        let requestedIdentity = identity
        if displayedIdentity != requestedIdentity {
            image = nil
            displayedIdentity = requestedIdentity
        } else if image != nil {
            return
        }
        let requestedPackageID = packageID
        let requestedAssetID = asset.id
        guard let url = await PackageThumbnailAvailability.waitForAvailable(
            loadOnce: { await package.loadThumbnail(packageID: requestedPackageID, itemID: requestedAssetID) },
            cachedURL: { package.thumbnailURL(packageID: requestedPackageID, itemID: requestedAssetID) },
            shouldWait: { package.isBusy && package.job?.id == requestedPackageID }),
              !Task.isCancelled, displayedIdentity == requestedIdentity else { return }
        // Retry/lifecycle changes keep an already decoded image in place. Only
        // this cell's state changes when its first available preview arrives.
        image = UIImage(contentsOfFile: url.path)?.preparingForDisplay()
    }
}

private struct PackageLibraryPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(RelayTheme.onAccent)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(minHeight: 52)
            .background(RelayTheme.accent, in: RoundedRectangle(cornerRadius: 18))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}

private enum PackageLibraryText {
    static func mediaSummary(_ entry: PackageLibraryEntry) -> String {
        var parts: [String] = []
        if entry.photoCount > 0 { parts.append(L10n.tr("%@ 张照片", String(describing: entry.photoCount))) }
        if entry.videoCount > 0 { parts.append(L10n.tr("%@ 段视频", String(describing: entry.videoCount))) }
        let unknown = max(0, entry.totalCount - entry.photoCount - entry.videoCount)
        if unknown > 0 { parts.append(L10n.tr("%@ 项素材", String(describing: unknown))) }
        return parts.isEmpty ? L10n.tr("照片包") : parts.joined(separator: " · ")
    }

    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }

    static func status(_ phase: PackagePhase) -> String {
        switch phase {
        case .draft: return L10n.tr("草稿")
        case .preparing: return L10n.tr("准备中")
        case .packing: return L10n.tr("打包中")
        case .paused: return L10n.tr("已暂停")
        case .ready: return L10n.tr("已就绪")
        case .failed: return L10n.tr("需处理")
        }
    }

    static func size(_ entry: PackageLibraryEntry) -> String {
        if entry.phase == .draft { return L10n.tr("分享时打包") }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.bytes), countStyle: .file)
        return entry.phase == .ready ? bytes : L10n.tr("已打包 %@", String(describing: bytes))
    }

    static func detailSummary(_ entry: PackageLibraryEntry) -> String {
        if entry.issue != nil { return L10n.tr("需处理") }
        if entry.phase == .draft { return L10n.tr("草稿") }
        if entry.phase == .ready { return "\(status(entry.phase)) · \(size(entry))" }
        return "\(status(entry.phase)) · \(entry.completedCount) / \(entry.totalCount)"
    }

    static func accessibilitySummary(_ entry: PackageLibraryEntry) -> String {
        [mediaSummary(entry), date(entry.createdAt), detailSummary(entry)].joined(separator: "，")
    }
}

/// Drafts are editable content, not an interrupted packaging task. Sharing can
/// start their first archive build, including for file-based albums.
enum PackageAlbumEditingPresentation {
    static func canResume(_ phase: PackagePhase) -> Bool { phase == .paused || phase == .failed }
    static func canShare(assetCount: Int, hasIssue: Bool, isBusy: Bool) -> Bool {
        assetCount > 0 && !hasIssue && !isBusy
    }
}
