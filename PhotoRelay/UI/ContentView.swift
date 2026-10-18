import SwiftUI
import Foundation
import UIKit

enum RelayTheme {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.40, green: 0.82, blue: 0.68, alpha: 1)
        : UIColor(red: 0.04, green: 0.36, blue: 0.28, alpha: 1) })
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.035, green: 0.16, blue: 0.12, alpha: 1) : .white })
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.075, green: 0.085, blue: 0.08, alpha: 1)
        : UIColor(red: 0.965, green: 0.975, blue: 0.958, alpha: 1) })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let paleAccent = accent.opacity(0.09)
    static let warning = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.76, blue: 0.36, alpha: 1)
        : UIColor(red: 0.52, green: 0.29, blue: 0.04, alpha: 1) })
}

struct ContentView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    @ObservedObject var package: PackageController
    @ObservedObject var inbox: IncomingArchiveInbox
    @ObservedObject var liveActivities: TransferLiveActivityCoordinator
    let activityBridge: TransferLiveActivityBridge
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [WorkflowRoute] = []
    @State private var activeSheet: DropackSheet?
    @State private var pendingSendSource: SendSourceChoice?
    @State private var librarySection: AlbumLibrarySection = .sent
    @State private var pendingSendFiles: [PendingSource] = []
    @State private var renamingPackageID: UUID?
    @State private var albumName = ""
    @State private var activeAlert: DropackAlert?
    @State private var pickerSelection: PendingSource?
    @State private var pendingSource: PendingSource?
    @State private var openingSourceID: UUID?
    @State private var pendingPhotos: PhotoPickerSelection?
    @State private var pendingReselectionID: UUID?
    @State private var waitingToOpen = false
    @State private var importPauseRequested = false
    @State private var requestingPhotos = false
    @State private var availableBytes: Int64?
    @State private var uiMessage: String?
    @State private var shareResult: String?
    @State private var automaticOpenAttempts = Set<UUID>()
    @State private var preparingShare = false
    @State private var sheetDismissalFinished = true
    @State private var approvedReplacementID: UUID?
    @State private var pendingTaskNavigation: Workflow?
    @State private var sendJobID: UUID?
    @State private var sendDraftID = UUID()
    @State private var creatingPackage = false
    @State private var selectedPhotoCount = 0
    @State private var taskCoverImage: UIImage?
    @State private var taskCoverJobID: UUID?
    @State private var taskCoverAssetID: String?

    private var working: Bool { controller.isBusy || controller.isPreparing || package.isBusy || creatingPackage }

    private var navigationContent: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                page {
                    home
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { settingsToolbar }
                .navigationDestination(for: WorkflowRoute.self) { route in
                    if route.workflow == .settings {
                        SettingsView(onHelp: { activeSheet = .help })
                    } else {
                    ObservedWorkflowDestination(controller: controller, package: package, inbox: inbox) {
                        page {
                            switch route.workflow {
                            case .settings:
                                EmptyView()
                            case .preparingAlbum:
                                VStack(alignment: .leading, spacing: 16) {
                                    if creatingPackage {
                                        ProgressView(L10n.tr("正在准备分享相册…"))
                                    } else {
                                        Label(L10n.tr(package.message ?? "未能打开所选文件，请重新选择。"), systemImage: "exclamationmark.circle")
                                            .foregroundStyle(RelayTheme.warning)
                                    }
                                }.padding(.vertical, 32)
                            case .preparingSource:
                                if controller.isPreparing || openingSourceID != nil {
                                    HStack(spacing: 12) { ProgressView(); Text(L10n.tr("正在读取文件…")) }
                                        .padding(.vertical, 32).accessibilityIdentifier("importScanning")
                                } else {
                                    ContentUnavailableView(L10n.tr("未能打开文件"), systemImage: "doc.badge.ellipsis",
                                        description: Text(L10n.tr(controller.message ?? "请重新选择原文件。")))
                                    if controller.requiresReset {
                                        Button(L10n.tr("清除损坏记录"), role: .destructive) { activeAlert = .clearImport }
                                    }
                                }
                            case let .receivedAlbum(id):
                                if controller.job?.isSharedAlbum == true, controller.job?.albumID == id {
                                    importDetail
                                } else { unavailableAlbum }
                            case let .oneTimeImport(id):
                                if controller.job?.id == id, controller.job?.isSharedAlbum == false {
                                    importDetail
                                } else { unavailableImport }
                            case .packages:
                                if package.requiresReset {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(L10n.tr(package.message ?? "打包记录需要处理"))
                                            .font(.footnote).foregroundStyle(RelayTheme.warning)
                                        Button(L10n.tr("清除损坏记录"), role: .destructive) { activeAlert = .clearPackage }
                                            .disabled(working || (package.job == nil && package.recoveryFailureID == nil))
                                            .accessibilityIdentifier("clearDamagedPackageButton")
                                    }.surface()
                                }
                                ShareAlbumLibraryView(package: package, importer: controller, selection: $librarySection,
                                    onOpenSent: openPackage, onOpenReceived: openReceivedAlbum)
                            case let .package(albumID):
                                if let id = packageSnapshotID(for: albumID) {
                                    PackageLibraryDetailView(package: package, packageID: id,
                                        onShare: { shareArchive($0, packageID: id) },
                                        onResume: { Task { await package.resume(packageID: id) } },
                                        onDelete: { activeAlert = .deletePackage(id) },
                                        onRename: { beginRename(id) },
                                        onReselect: {
                                            pendingReselectionID = package.canReselectPhotos ? id : nil
                                            choosePhotos()
                                        },
                                        onDetails: { activeSheet = .sentAlbumDetails(id) },
                                        onUpdated: showPackageDetail, onPreview: previewSentAsset,
                                        actionsDisabled: working || preparingShare)
                                } else { unavailableAlbum }
                            }
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            importActionBar(for: route.workflow)
                        }
                        .navigationTitle(route.workflow.title)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A sibling reserves real height even when a destination has its own
            // bottom action inset. Nested NavigationStack safe areas can ignore an
            // outer inset on iPad, causing the task to cover the import button.
            packageTaskFooter
        }
        .tint(RelayTheme.accent)
    }

    private var presentedContent: some View {
        navigationContent
        .background {
            ArchiveSharePresenter(request: activeSheet?.archiveShareRequest) { requestID, result in
                guard let request = activeSheet?.archiveShareRequest, request.id == requestID else { return }
                if package.job?.id == request.packageID { shareResult = result }
                activeSheet = nil
                sheetDismissed()
            }
        }
        .alert(L10n.tr("相册名称"), isPresented: Binding(get: { renamingPackageID != nil }, set: { if !$0 { renamingPackageID = nil } })) {
            TextField(L10n.tr("相册名称"), text: $albumName)
            Button(L10n.tr("保存")) {
                guard let id = renamingPackageID else { return }
                renamingPackageID = nil
                let title = albumName
                Task { _ = await package.rename(packageID: id, title: title, onCreated: { updated in
                    showPackageDetail(updated)
                }) }
            }
            Button(L10n.tr("取消"), role: .cancel) { renamingPackageID = nil }
        }
        .sheet(item: nonShareSheet, onDismiss: {
            // A late SwiftUI dismissal must not release the native share request.
            if activeSheet?.archiveShareRequest == nil { sheetDismissed() }
        }) { sheet in
            VStack(spacing: 0) {
                Group {
                    switch sheet {
                    case .sendSources:
                        SendSourceSheet { choice in
                            pendingSendSource = choice
                            activeSheet = nil
                        }
                    case .sendFiles:
                        SendSourcePicker(onSelect: { urls in
                            pendingSendFiles = urls.map { PendingSource(url: $0) }
                            activeSheet = nil
                        }, onCancel: { activeSheet = nil }).ignoresSafeArea()
                    case .photos:
                        PhotoPicker { selection, error in
                            pendingPhotos = selection.isEmpty ? nil : selection
                            if selection.isEmpty { pendingReselectionID = nil }
                            if let error { uiMessage = error }
                            activeSheet = nil
                        }.ignoresSafeArea()
                    case let .source(kind, relink):
                        SourcePicker(kind: kind, onSelect: { url in
                            pickerSelection = PendingSource(url: url, relink: relink)
                            activeSheet = nil
                        }, onCancel: { activeSheet = nil }).ignoresSafeArea()
                    case .share:
                        EmptyView() // Projected out by nonShareSheet; UIKit owns sharing.
                    case let .mediaPreview(request):
                        AlbumMediaPreview(request: request, package: package)
                    case .receivedAlbumDetails:
                        ReceivedAlbumDetailsSheet(controller: controller)
                    case let .sentAlbumDetails(id):
                        PackageAlbumDetailsSheet(package: package, packageID: id)
                    case .help:
                        HelpView()
                    case .packageDetails:
                        PackageTaskDetails(package: package, activity: package.activity,
                                           pauseRequested: package.isPauseRequested, shareResult: shareResult,
                                           onDismiss: { activeSheet = nil })
                    case let .issues(kind):
                        IssueListView(controller: controller, kind: kind)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if sheet.showsPackageTask { packageTaskFooter }
            }
            .onAppear { sheetDismissalFinished = false }
        }
        .alert(alertTitle, isPresented: Binding(get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } })) {
            alertActions
        } message: { Text(L10n.tr(alertMessage)) }
    }

    /// Preserve one modal admission guard while letting UIKit own system sharing.
    private var nonShareSheet: Binding<DropackSheet?> {
        Binding(get: { activeSheet?.archiveShareRequest == nil ? activeSheet : nil }, set: { value in
            guard activeSheet?.archiveShareRequest == nil else { return }
            activeSheet = value
        })
    }

    private func presentShare(url: URL, packageID: UUID) {
        guard activeSheet == nil, sheetDismissalFinished else { return }
        sheetDismissalFinished = false
        activeSheet = .share(ArchiveShareRequest(url: url, packageID: packageID))
    }

    private var importDetail: some View {
        ReceivedAlbumDetailView(controller: controller, actionsDisabled: package.isBusy,
            onRelink: { if let job = controller.job { activeSheet = .source(job.source.kind, relink: true) } },
            onIssues: { activeSheet = .issues($0) },
            onClear: { activeAlert = .clearImport },
            onShare: shareReceivedAlbum,
            onDetails: { activeSheet = .receivedAlbumDetails },
            onPreview: previewReceivedAsset)
    }

    private func previewSentAsset(packageID: UUID, asset: PackageAsset) {
        guard activeSheet == nil,
              let job = package.library.first(where: { $0.id == packageID })?.job
                ?? (package.job?.id == packageID ? package.job : nil),
              let exactAsset = job.assets.first(where: { $0.id == asset.id }) else { return }
        activeSheet = .mediaPreview(AlbumMediaPreviewRequest(title: exactAsset.title ?? job.displayTitle,
            source: .sent(job, exactAsset)))
    }

    private func previewReceivedAsset(_ item: ImportItem) {
        guard activeSheet == nil, let job = controller.job,
              let exactItem = job.items.first(where: { $0.id == item.id }) else { return }
        activeSheet = .mediaPreview(AlbumMediaPreviewRequest(title: (exactItem.relativePath as NSString).lastPathComponent,
            source: .received(job, exactItem)))
    }

    @ViewBuilder
    private func importActionBar(for workflow: Workflow) -> some View {
        if let job = controller.job,
           workflow == (job.isSharedAlbum ? .receivedAlbum(job.albumID) : .oneTimeImport(job.id)) {
            ReceivedAlbumActionBar(controller: controller, actionsDisabled: package.isBusy,
                onRelink: { activeSheet = .source(job.source.kind, relink: true) },
                onFinish: {
                    Task {
                        if await controller.finishOneTimeImport() { path = []; uiMessage = nil }
                    }
                })
        }
    }

    private var unavailableAlbum: some View {
        ContentUnavailableView(L10n.tr("相册不在本机"), systemImage: "photo.stack",
            description: Text(L10n.tr("请重新打开原来的 Dropack 文件。")))
    }

    private var unavailableImport: some View {
        ContentUnavailableView(L10n.tr("导入任务已结束"), systemImage: "checkmark.circle",
            description: Text(L10n.tr("已保存的照片和视频仍在系统相册中。")))
    }

    private var lifecycleContent: some View {
        presentedContent
        .task {
            refreshAvailableSpace()
            activityBridge.sceneDidBecomeActive()
            openIncomingWhenReady()
            openActivityWhenReady()
            openAlbumLinkWhenReady()
        }
        .task(id: "\(package.job?.id.uuidString ?? "none")-\(package.job?.assets.first?.id ?? "none")-\(package.job?.assets.first?.isCompleted ?? false)-\(package.isBusy)") {
            if taskCoverJobID != package.job?.id || taskCoverAssetID != package.job?.assets.first?.id {
                taskCoverImage = nil
                taskCoverJobID = package.job?.id
                taskCoverAssetID = package.job?.assets.first?.id
            }
            guard taskCoverImage == nil, let job = package.job, let asset = job.assets.first,
                  let url = await PackageThumbnailAvailability.waitForAvailable(
                    loadOnce: { await package.loadThumbnail(packageID: job.id, itemID: asset.id) },
                    cachedURL: { package.thumbnailURL(packageID: job.id, itemID: asset.id) },
                    shouldWait: { package.isBusy && package.job?.id == job.id }),
                  !Task.isCancelled, package.job?.id == job.id,
                  package.job?.assets.first?.id == asset.id,
                  let image = UIImage(contentsOfFile: url.path)?.preparingForDisplay() else { return }
            taskCoverImage = image
        }
        .onChange(of: creatingPackage) { _, creating in
            if !creating { resumePendingOpen(); openIncomingWhenReady(); openAlbumLinkWhenReady() }
        }
        .onChange(of: openingSourceID) { _, id in
            if id == nil { openActivityWhenReady(); openAlbumLinkWhenReady() }
        }
        .onChange(of: preparingShare) { _, preparing in
            if !preparing { openAlbumLinkWhenReady() }
        }
        .onChange(of: inbox.sources.map(\.id)) { _, _ in openIncomingWhenReady() }
        .onChange(of: inbox.activityRequest?.id) { _, _ in openActivityWhenReady() }
        .onChange(of: inbox.albumNavigationRequest?.id) { _, _ in openAlbumLinkWhenReady() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                importPauseRequested = controller.isBusy
                controller.sceneDidBecomeInactive()
                package.sceneDidEnterBackground()
                activityBridge.sceneDidEnterBackground()
            } else if phase == .active {
                package.sceneDidBecomeActive()
                activityBridge.sceneDidBecomeActive()
                refreshAvailableSpace()
                resumePendingOpen()
                resumeApprovedReplacement()
                openIncomingWhenReady()
                openActivityWhenReady()
                openAlbumLinkWhenReady()
            }
        }
    }

    var body: some View {
        lifecycleContent
        .onChange(of: controller.isBusy) { _, busy in
            if !busy { importPauseRequested = false; refreshAvailableSpace(); resumePendingOpen(); openIncomingWhenReady(); openAlbumLinkWhenReady() }
        }
        .onChange(of: controller.isPreparing) { _, preparing in
            if !preparing { refreshAvailableSpace(); resumePendingOpen(); openIncomingWhenReady(); openAlbumLinkWhenReady() }
        }
        .onChange(of: package.isBusy) { _, busy in
            if !busy {
                refreshAvailableSpace(); resumePendingOpen()
                openIncomingWhenReady(); openActivityWhenReady(); openAlbumLinkWhenReady()
            }
        }
        .onChange(of: controller.job?.savedCount) { _, _ in refreshAvailableSpace() }
        .onChange(of: activeAlert == nil) { _, dismissed in
            if dismissed {
                resumeApprovedReplacement()
                openIncomingWhenReady()
                openActivityWhenReady()
                openAlbumLinkWhenReady()
            }
        }
        .onChange(of: approvedReplacementID) { _, _ in resumeApprovedReplacement() }
        .onChange(of: pickerSelection?.id) { _, _ in consumeDismissedSelection() }
        .onChange(of: pendingPhotos?.count) { _, _ in consumeDismissedSelection() }
        .onChange(of: pendingSendFiles.map(\.id)) { _, _ in consumeDismissedSelection() }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if inbox.isTestMode {
                    Label(L10n.tr("开发测试模式 · 使用真实导入流程"), systemImage: "hammer")
                        .font(.caption).foregroundStyle(RelayTheme.warning)
                        .accessibilityIdentifier("debugImportMode")
                }
                if let source = inbox.sources.first { incomingNotice(source) }
                if let uiMessage { notice(uiMessage) }
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            // The task footer is a sibling below the navigation container;
            // this is ordinary spacing below the document content.
            .padding(.bottom, 36)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(RelayTheme.background)
    }

    @ViewBuilder
    private var packageTaskFooter: some View {
        if package.job.map({ $0.phase != .ready && $0.phase != .draft }) == true || package.requiresReset
            || (package.isBusy && (package.canPause || package.isPauseRequested)) {
            PackageTaskBanner(package: package, activity: package.activity,
                canResume: !working && !preparingShare,
                onPause: { package.pause() }, onResume: { package.resume() },
                onDetails: showCurrentPackageTask, coverImage: taskCoverImage)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(RelayTheme.background.opacity(0.96))
        }
    }

    /// Opening the task is navigation only. In particular, do not call
    /// openPackage(), which may refresh a linked system album while idle.
    private func showCurrentPackageTask() {
        let destination: Workflow
        if package.requiresReset {
            destination = .packages
        } else if let job = package.job,
                  !package.isBusy || package.activity.snapshot.packageID == job.id {
            destination = .package(job.stableAlbumID)
        } else {
            destination = .preparingAlbum
        }
        if activeSheet != nil {
            pendingTaskNavigation = destination
            // Keep native sharing's ownership/scope until its actual dismissal.
            if activeSheet?.archiveShareRequest == nil { activeSheet = nil }
        } else {
            navigate(destination)
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { navigate(.settings) } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(L10n.tr("设置"))
                .accessibilityIdentifier("settingsButton")
        }
    }

    @ViewBuilder
    private func columns<Summary: View, Actions: View>(@ViewBuilder summary: () -> Summary, @ViewBuilder actions: () -> Actions) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 28) { summary(); actions() }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 48) {
                    summary().frame(width: 280, alignment: .leading)
                    actions().frame(minWidth: 350, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 28) { summary(); actions() }
            }
        }
    }

    private var home: some View {
        columns {
            VStack(alignment: .leading, spacing: 20) {
                DropackBrandLogo(width: 230)
                Text(L10n.tr("大文件，批量快传。"))
                    .font(.title2.weight(.semibold))
            }.padding(.top, 20)
        } actions: {
            VStack(alignment: .leading, spacing: 20) {
                if hasUnfinishedImport { currentTasks }
                VStack(spacing: 12) {
                    actionRow(L10n.tr("发送"), subtitle: L10n.tr("选择照片或文件"), symbol: "arrow.up.right", primary: true) {
                        beginNewSend()
                    }.disabled(working || requestingPhotos).accessibilityIdentifier("sendPhotosButton")
                    actionRow(L10n.tr("收取"), subtitle: L10n.tr("打开分享相册或文件"), symbol: "arrow.down.left", primary: false) {
                        chooseFiles(.mediaFile)
                    }.disabled(working || requestingPhotos).accessibilityIdentifier("importPackageButton")
                }
                Button { navigate(.packages) } label: {
                    HStack(spacing: 14) {
                        if let entry = package.library.first {
                            PackageCoverView(package: package, entry: entry).frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if let job = controller.library.first {
                            ReceivedAlbumCover(controller: controller, job: job).frame(width: 56, height: 56)
                        } else {
                            Image(systemName: "square.grid.2x2").font(.title2)
                                .frame(width: 56, height: 56).background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.tr("分享相册")).font(.headline).foregroundStyle(RelayTheme.ink)
                            Text(package.library.count + controller.library.count == 0 ? L10n.tr("发送与收到的相册") : L10n.tr("%@ 个相册", String(describing: package.library.count + controller.library.count)))
                                .font(.footnote).foregroundStyle(RelayTheme.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward").font(.caption).foregroundStyle(RelayTheme.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("packageLibraryButton")
                if !hasUnfinishedImport, let job = controller.job {
                    taskRow(L10n.tr("上次已存好"), detail: mediaSummary(job), busy: false) { showImportDetail() }
                }
                Label(L10n.tr("本机处理，无需账号"), systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(RelayTheme.secondary)
                    .padding(.top, 4)
            }.padding(.top, 20)
        }
    }

    private var hasUnfinishedImport: Bool {
        controller.requiresReset || controller.isPreparing
            || controller.job.map { !fullySaved($0) } == true
    }

    private var currentTasks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("继续上次")).font(.caption.weight(.semibold)).foregroundStyle(RelayTheme.secondary)
            if let job = controller.job, !fullySaved(job) {
                taskRow(L10n.tr("继续存入相册"), detail: L10n.tr("已保存 %@ / %@ 项", String(describing: job.savedCount), String(describing: job.items.count)), busy: controller.isBusy) { showImportDetail() }
            } else if controller.isPreparing || controller.requiresReset {
                taskRow(controller.requiresReset ? L10n.tr("导入记录需要处理") : L10n.tr("正在读取素材"), detail: L10n.tr(controller.currentStage), busy: controller.isPreparing) { showImportDetail() }
            }
        }.surface()
    }

    private func mediaSummary(_ job: ImportJob) -> String {
        let photos = job.items.filter { $0.kind == .photo }.count
        let videos = job.items.count - photos
        if photos == 0 { return L10n.tr("%@ 个视频", String(describing: videos)) }
        if videos == 0 { return L10n.tr("%@ 张照片", String(describing: photos)) }
        return L10n.tr("%@ 张照片 · %@ 个视频", String(describing: photos), String(describing: videos))
    }

    private func incomingNotice(_ source: PendingSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(inbox.sources.count > 1 ? L10n.tr("收到 %@ 个待打开文件", String(describing: inbox.sources.count))
                  : source.url.pathExtension.lowercased() == "dropack" ? L10n.tr("收到一个分享相册") : L10n.tr("收到一个文件"),
                  systemImage: "tray.and.arrow.down")
                .font(.headline)
            Text(source.url.lastPathComponent).font(.subheadline).lineLimit(2).truncationMode(.middle)
            if openingSourceID == source.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("正在读取文件…")).font(.subheadline)
                }
            } else if waitingToOpen {
                Label(L10n.tr("等待当前任务安全暂停…"), systemImage: "pause.circle").font(.subheadline)
            } else {
                Button(working ? L10n.tr("暂停当前任务并打开") : L10n.tr("打开文件")) { requestOpen(source) }
                    .font(.subheadline.weight(.semibold))
                    .disabled(activeSheet != nil || activeAlert != nil || controller.requiresReset)
                    .accessibilityIdentifier("openIncomingPackageButton")
                Button(L10n.tr("暂不打开")) { inbox.remove(source) }
                    .font(.footnote).foregroundStyle(RelayTheme.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 16))
    }

    private func storageNote(sending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(availableBytes.map { L10n.tr("可用空间约 %@", String(describing: byteText(UInt64(max(0, $0))))) } ?? L10n.tr("请预留足够的手机空间"), systemImage: "internaldrive")
                .font(.footnote.weight(.medium))
            Text(sending ? L10n.tr("打包需要额外空间保存照片包和当前文件缓存。原照片会保留；锁屏或进入后台会暂停。") : L10n.tr("请预留新增相册内容和当前文件缓存的空间。原文件会保留；锁屏或进入后台会暂停。"))
                .font(.footnote).lineSpacing(3)
        }.foregroundStyle(RelayTheme.secondary)
    }

    private func actionRow(_ title: String, subtitle: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(primary ? "SendArtwork" : "ReceiveArtwork")
                    .resizable().scaledToFit()
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 56 : 84,
                           height: dynamicTypeSize.isAccessibilitySize ? 56 : 84)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.subheadline).opacity(primary ? 0.88 : 0.72)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.callout.weight(.semibold))
                    .opacity(0.7).accessibilityHidden(true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(primary ? RelayTheme.onAccent : RelayTheme.ink)
            .background(primary ? RelayTheme.accent : RelayTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }

    private func taskRow(_ title: String, detail: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(RelayTheme.ink)
                    Text(detail).font(.footnote).foregroundStyle(RelayTheme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(RelayTheme.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
        }.buttonStyle(DropackPrimaryButtonStyle())
    }

    private func notice(_ message: String, symbol: String = "info.circle") -> some View {
        Label { Text(L10n.tr(message)).fixedSize(horizontal: false, vertical: true).lineSpacing(3) } icon: { Image(systemName: symbol) }
            .font(.subheadline).foregroundStyle(RelayTheme.ink)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 14))
    }

    private func conflictNotice(_ text: String) -> some View {
        Label(L10n.tr(text), systemImage: "pause.circle").font(.footnote).foregroundStyle(RelayTheme.warning)
    }

    private func issueButton(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(RelayTheme.warning)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(RelayTheme.ink)
                    Text(detail).font(.footnote).foregroundStyle(RelayTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(RelayTheme.secondary)
            }
        }.buttonStyle(.plain)
    }

    private func navigate(_ workflow: Workflow, renew: Bool = false) {
        guard renew || path.last?.workflow != workflow else { return }
        let destination = WorkflowRoute(workflow: workflow)
        if workflow != .packages, let library = path.first, library.workflow == .packages {
            path = [library, destination]
        } else { path = [destination] }
    }

    private func beginNewSend() {
        guard !working, !requestingPhotos else { return }
        pendingReselectionID = nil
        sendDraftID = UUID()
        sendJobID = nil
        shareResult = nil
        uiMessage = nil
        activeSheet = .sendSources
    }

    private func showSendJob(_ id: UUID) {
        sendDraftID = UUID()
        sendJobID = id
        openPackage(id)
    }

    private func packageSnapshotID(for albumID: UUID) -> UUID? {
        // A task link must resolve the operation's actual snapshot even if the
        // library has another revision of the same stable album identity.
        if let job = package.job, job.stableAlbumID == albumID, job.phase != .ready { return job.id }
        return package.library.first(where: { $0.job.stableAlbumID == albumID })?.id
            ?? (package.job?.stableAlbumID == albumID ? package.job?.id : nil)
    }

    private func showPackageDetail(_ snapshotID: UUID) {
        guard let job = package.library.first(where: { $0.id == snapshotID })?.job
            ?? (package.job?.id == snapshotID ? package.job : nil) else { return }
        navigate(.package(job.stableAlbumID))
    }

    private func showImportDetail() {
        guard let job = controller.job else { navigate(.preparingSource); return }
        navigate(job.isSharedAlbum ? .receivedAlbum(job.albumID) : .oneTimeImport(job.id))
    }

    private func openAlbumLinkWhenReady() {
        guard let request = inbox.albumNavigationRequest, scenePhase == .active,
              !working, !preparingShare, sheetDismissalFinished,
              activeSheet == nil, activeAlert == nil, pendingSource == nil,
              openingSourceID == nil else { return }
        inbox.albumNavigationRequest = nil
        uiMessage = nil
        switch request.destination {
        case let .library(section):
            librarySection = section
            navigate(.packages)
        case let .sent(id):
            librarySection = .sent
            path = [WorkflowRoute(workflow: .packages), WorkflowRoute(workflow: .package(id))]
            // A link opens the stored album without starting an export or sync.
        case let .received(id):
            librarySection = .received
            Task {
                if controller.job?.isSharedAlbum != true || controller.job?.albumID != id {
                    _ = await controller.activate(albumID: id)
                }
                path = [WorkflowRoute(workflow: .packages), WorkflowRoute(workflow: .receivedAlbum(id))]
            }
        case let .importing(id):
            navigate(.oneTimeImport(id))
        }
    }

    private func openPackage(_ id: UUID) {
        showPackageDetail(id)
        guard !working else { return }
        Task {
            // The route uses the album ID; refreshing a snapshot keeps the same
            // page identity and resolves its newest package on the next render.
            _ = await package.refreshAlbum(packageID: id)
        }
    }

    private func openReceivedAlbum(_ id: UUID) {
        guard !working else { return }
        Task {
            if await controller.activate(albumID: id) { navigate(.receivedAlbum(id)) }
        }
    }

    private func beginRename(_ id: UUID) {
        albumName = package.library.first(where: { $0.id == id })?.job.displayTitle ?? ""
        renamingPackageID = id
    }

    private func shareReceivedAlbum() {
        guard let job = controller.job, !working, !preparingShare,
              activeSheet == nil, sheetDismissalFinished else { return }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            if let url = await controller.shareURL(), controller.job?.id == job.id,
               scenePhase == .active, activeSheet == nil, sheetDismissalFinished {
                presentShare(url: url, packageID: job.id)
            } else {
                controller.finishSharing()
            }
        }
    }

    private func chooseFiles(_ kind: SourceKind) {
        guard !working, !requestingPhotos else { return }
        activeSheet = .source(kind, relink: false)
    }

    private func shareArchive(_ format: PackageFileFormat, packageID: UUID) {
        guard !working, !preparingShare, activeSheet == nil, sheetDismissalFinished,
              let albumID = package.library.first(where: { $0.id == packageID })?.job.stableAlbumID else { return }
        preparingShare = true
        shareResult = nil
        Task {
            defer { preparingShare = false }
            if let url = await package.shareURL(packageID: packageID, format: format, onCreated: { updated in
                showPackageDetail(updated)
            }), scenePhase == .active, activeSheet == nil, sheetDismissalFinished {
                let sharedSnapshot = packageSnapshotID(for: albumID) ?? packageID
                showPackageDetail(sharedSnapshot)
                presentShare(url: url, packageID: sharedSnapshot)
            }
        }
    }

    /// URL delivery can arrive before checkpoint restoration finishes. Try each
    /// incoming event once after the app becomes idle; failed scans stay retryable.
    /// Scanning never starts Photos writes, and replacing an existing job still
    /// requires the confirmation in considerPendingSource().
    private func openIncomingWhenReady() {
        guard scenePhase == .active, !working, !preparingShare, sheetDismissalFinished,
              activeSheet == nil, activeAlert == nil, pendingSource == nil,
              pickerSelection == nil, pendingPhotos == nil, openingSourceID == nil,
              let source = inbox.sources.first,
              !automaticOpenAttempts.contains(source.id) else { return }
        automaticOpenAttempts.insert(source.id)
        requestOpen(source)
    }

    private func choosePhotos() {
        guard !working, !requestingPhotos else { return }
        uiMessage = nil
        requestingPhotos = true
        Task {
            let allowed = await package.requestPhotoAccess()
            requestingPhotos = false
            guard allowed, !working, scenePhase != .background else { return }
            activeSheet = .photos
        }
    }

    private func sheetDismissed() {
        sheetDismissalFinished = true
        controller.finishSharing()
        if let destination = pendingTaskNavigation {
            pendingTaskNavigation = nil
            navigate(destination)
            return
        }
        if let choice = pendingSendSource {
            pendingSendSource = nil
            if choice == .photos { choosePhotos() }
            else if !working { activeSheet = .sendFiles }
            return
        }
        resumePendingOpen()
        resumeApprovedReplacement()
        consumeDismissedSelection()
        openActivityWhenReady()
        openAlbumLinkWhenReady()
    }

    private func openActivityWhenReady() {
        guard let request = inbox.activityRequest, scenePhase == .active,
              activeSheet == nil, activeAlert == nil, openingSourceID == nil,
              !(package.isBusy && !package.canPause) else { return }
        inbox.activityRequest = nil
        switch request.destination.kind {
        case .packaging:
            if package.library.contains(where: { $0.id == request.destination.jobID }) {
                showPackageDetail(request.destination.jobID)
            } else {
                liveActivities.clear(jobID: request.destination.jobID)
                navigate(.packages)
                uiMessage = "这个照片包已不在本机。"
            }
        case .importing:
            if controller.job?.id == request.destination.jobID { showImportDetail() }
            else {
                liveActivities.clear(jobID: request.destination.jobID)
                path = []; uiMessage = "这个导入任务已结束。"
            }
        }
    }

    /// UIKit may deliver its selected URL before or after its automatic modal
    /// dismissal. Drain on both events, but only after the sheet has closed; this
    /// also lets replacement confirmation appear from a free presentation host.
    private func consumeDismissedSelection() {
        guard sheetDismissalFinished, activeSheet == nil else { return }
        if let source = pickerSelection {
            pickerSelection = nil
            requestOpen(source)
        } else if !pendingSendFiles.isEmpty {
            startFilePackage()
        } else if pendingPhotos != nil {
            startPackage()
        } else {
            openIncomingWhenReady()
        }
    }

    private func startPackage() {
        guard let selection = pendingPhotos, !working else { return }
        pendingPhotos = nil
        selectedPhotoCount = selection.count
        sendJobID = nil
        creatingPackage = true
        navigate(.preparingAlbum, renew: true)
        shareResult = nil
        let draftID = sendDraftID
        let reselectionID = pendingReselectionID
        pendingReselectionID = nil
        Task {
            defer { creatingPackage = false }
            let onCreated: (UUID) -> Void = { id in
                if sendDraftID == draftID { sendJobID = id; showPackageDetail(id) }
            }
            let id: UUID?
            if let reselectionID {
                id = await package.reselect(packageID: reselectionID, selection: selection, onCreated: onCreated)
                if id == nil { showPackageDetail(reselectionID) }
            } else {
                id = await package.create(selection: selection, onCreated: onCreated)
            }
            if sendDraftID == draftID { sendJobID = id }
        }
    }

    private func startFilePackage() {
        guard !pendingSendFiles.isEmpty, !working else { return }
        let sources = pendingSendFiles
        pendingSendFiles = []
        creatingPackage = true
        navigate(.preparingAlbum, renew: true)
        uiMessage = nil
        Task {
            defer { creatingPackage = false; sources.forEach { $0.releaseScope() } }
            _ = await package.create(fileURLs: sources.map(\.url), onCreated: { id in
                showPackageDetail(id)
            })
        }
    }

    private func requestOpen(_ source: PendingSource) {
        automaticOpenAttempts.insert(source.id)
        pendingSource = source
        if working {
            waitingToOpen = true
            importPauseRequested = controller.isBusy
            controller.pause()
            package.pause()
        } else {
            considerPendingSource()
        }
    }

    private func resumePendingOpen() {
        guard waitingToOpen, !working, scenePhase == .active,
              activeSheet == nil, activeAlert == nil, sheetDismissalFinished else { return }
        waitingToOpen = false
        considerPendingSource()
    }

    private func considerPendingSource() {
        guard let source = pendingSource, !working else { return }
        guard !controller.requiresReset else {
            showImportDetail()
            uiMessage = "请先处理无法读取的导入记录，再打开新照片包。"
            return
        }
        if source.relink || controller.job == nil {
            openSource(replacing: false)
        } else if let job = controller.job, fullySaved(job) {
            // A finished import has no remaining work to discard. Keep the same
            // deferred navigation path as an explicitly approved replacement.
            approvedReplacementID = source.id
        } else {
            // Do not push a NavigationStack destination in the same transaction
            // as this alert. On iOS 18 that can leave a path with no visible page.
            activeAlert = .replaceImport
        }
    }

    private func resumeApprovedReplacement() {
        guard let approvedReplacementID, pendingSource?.id == approvedReplacementID,
              scenePhase == .active, activeAlert == nil, activeSheet == nil,
              sheetDismissalFinished, !working else { return }
        self.approvedReplacementID = nil
        openSource(replacing: true)
    }

    private func openSource(replacing: Bool) {
        guard let source = pendingSource, !working else { return }
        pendingSource = nil
        openingSourceID = source.id
        uiMessage = nil
        navigate(.preparingSource, renew: true)
        Task {
            defer { openingSourceID = nil }
            let accepted: Bool
            if source.relink { accepted = await controller.relinkSource(source.url) }
            else if replacing { accepted = await controller.replaceSource(source.url) }
            else { accepted = await controller.selectSource(source.url) }

            // An idempotent reopen may accept a source without changing the job
            // UUID. Acknowledge actual acceptance, not a guessed identity change.
            if accepted {
                showImportDetail()
                inbox.remove(source)
                source.releaseScope()
            } else if !inbox.sources.contains(where: { $0.id == source.id }) {
                // A manual picker selection is owned only by this operation.
                source.releaseScope()
            }
        }
    }

    @ViewBuilder
    private var alertActions: some View {
        switch activeAlert {
        case .replaceImport:
            Button(L10n.tr("打开所选文件")) {
                approvedReplacementID = pendingSource?.id
                activeAlert = nil
            }
            Button(L10n.tr("保留当前任务"), role: .cancel) {
                approvedReplacementID = nil
                pendingSource = nil
            }
        case .clearImport:
            Button(L10n.tr("移除记录"), role: .destructive) {
                if let job = controller.job {
                    Task {
                        let removed = job.isSharedAlbum
                            ? await controller.deleteAlbum(albumID: job.albumID)
                            : await controller.discardCurrentImport()
                        if removed {
                            if job.isSharedAlbum { librarySection = .received; navigate(.packages) }
                            else { path = [] }
                        }
                    }
                } else { controller.clearJob() }
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        case let .deletePackage(id):
            Button(L10n.tr("删除本地分享包"), role: .destructive) {
                guard !working, !preparingShare, activeSheet == nil else { return }
                Task {
                    if await package.deletePackage(id: id) {
                        if sendJobID == id { sendJobID = nil }
                        shareResult = nil
                        navigate(.packages)
                        refreshAvailableSpace()
                    }
                }
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        case .clearPackage:
            Button(L10n.tr("清除照片包"), role: .destructive) { shareResult = nil; package.clear() }
            Button(L10n.tr("取消"), role: .cancel) {}
        case nil:
            Button(L10n.tr("好")) {}
        }
    }

    private var alertTitle: String {
        switch activeAlert {
        case .replaceImport: return L10n.tr("打开新的文件？")
        case .clearImport: return controller.job?.isSharedAlbum == true ? L10n.tr("移除这本分享相册？") : L10n.tr("清除这次导入记录？")
        case .deletePackage: return L10n.tr("删除本地分享包？")
        case .clearPackage: return L10n.tr("清除照片包与打包记录？")
        case nil: return ""
        }
    }

    private var alertMessage: String {
        switch activeAlert {
        case .replaceImport:
            return controller.job?.isSharedAlbum == true
                ? L10n.tr("当前相册的进度会保留，可稍后从分享相册列表继续。")
                : L10n.tr("当前导入尚未完成。进度会保留，重新选择原文件后可继续。")
        case .clearImport:
            return L10n.tr("移除本地记录和预览，原文件、系统相册及已保存的去重记录都会保留。")
        case .deletePackage, .clearPackage:
            return L10n.tr("只删除本地分享包和预览。系统相册、其中的照片和视频都会保留。")
        case nil: return ""
        }
    }

    private func refreshAvailableSpace() {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        availableBytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    private func fullySaved(_ job: ImportJob) -> Bool { !job.items.isEmpty && job.savedCount == job.items.count }

    private func importActionTitle(_ job: ImportJob) -> String {
        if importPauseRequested { return L10n.tr("正在暂停…") }
        if controller.isBusy { return L10n.tr("暂停导入") }
        if controller.needsRelink { return L10n.tr("重新连接原文件") }
        if !controller.canStart {
            if job.uncertainCount > 0 { return L10n.tr("请先核对待确认项目") }
            if job.failedCount > 0 { return L10n.tr("请先处理失败项目") }
            return L10n.tr("暂无待保存文件")
        }
        return job.savedCount > 0 || job.phase == .paused ? L10n.tr("继续保存到相册") : L10n.tr("开始保存到相册")
    }
}

private enum Workflow: Hashable {
    case settings, packages, preparingAlbum, preparingSource, package(UUID), receivedAlbum(UUID), oneTimeImport(UUID)
    var title: String {
        switch self {
        case .settings: return L10n.tr("设置")
        case .packages: return L10n.tr("分享相册")
        case .package, .receivedAlbum, .preparingAlbum: return L10n.tr("相册")
        case .oneTimeImport: return L10n.tr("导入")
        case .preparingSource: return L10n.tr("读取文件")
        }
    }
}

private struct WorkflowRoute: Hashable {
    let id = UUID()
    let workflow: Workflow
}

/// NavigationStack may retain its destination closure on iOS 18 even while the
/// root observes fresh controller state. Subscribe inside the destination itself,
/// including its toolbar, so progress completion and enabled actions update
/// without popping and pushing. The content closure retains the parent's State
/// locations and Bindings; it is evaluated anew for each controller publication.
private struct ObservedWorkflowDestination<Content: View>: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    @ObservedObject var package: PackageController
    @ObservedObject var inbox: IncomingArchiveInbox
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

private enum DropackAlert { case replaceImport, clearImport, deletePackage(UUID), clearPackage }
private enum DropackSheet: Identifiable {
    case sendSources, photos, sendFiles, source(SourceKind, relink: Bool), share(ArchiveShareRequest), help, packageDetails, receivedAlbumDetails, sentAlbumDetails(UUID), issues(IssueKind), mediaPreview(AlbumMediaPreviewRequest)
    var archiveShareRequest: ArchiveShareRequest? {
        if case let .share(request) = self { return request }
        return nil
    }
    /// Native Photos / Files / share UI owns its presentation and must not be
    /// decorated with app controls. Our own informational sheets retain the task.
    var showsPackageTask: Bool {
        switch self {
        case .help, .packageDetails, .receivedAlbumDetails, .sentAlbumDetails, .issues: return true
        case .sendSources, .photos, .sendFiles, .source, .share, .mediaPreview: return false
        }
    }
    var id: String {
        switch self {
        case .sendSources: return "send-sources"
        case .photos: return "photos"
        case .sendFiles: return "send-files"
        case let .source(kind, relink): return "source-\(kind.rawValue)-\(relink)"
        case let .share(request): return "share-\(request.id)"
        case let .mediaPreview(request): return "media-preview-\(request.id)"
        case .receivedAlbumDetails: return "received-album-details"
        case let .sentAlbumDetails(id): return "sent-album-details-\(id)"
        case .help: return "help"
        case .packageDetails: return "package-details"
        case let .issues(kind): return "issues-\(kind.rawValue)"
        }
    }
}

private struct SurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

private extension View {
    func surface() -> some View { modifier(SurfaceModifier()) }
}

func byteText(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
}

private struct DropackPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(RelayTheme.onAccent)
            .background(RelayTheme.accent, in: RoundedRectangle(cornerRadius: 15))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 15))
    }
}
