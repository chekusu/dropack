import QuickLook
import SwiftUI

/// A full-resolution native viewer, deliberately separate from the thumbnails
/// and from both the packaging and Photos-import state machines.
struct AlbumMediaPreview: View {
    let request: AlbumMediaPreviewRequest
    let package: PackageController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AlbumMediaPreviewModel()
    @State private var attempt = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if let lease = model.lease {
                    NativeAlbumMediaPreview(lease: lease, title: request.title)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("nativeAlbumMediaPreview")
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label(L10n.tr("无法预览"), systemImage: "exclamationmark.circle")
                    } description: {
                        Text(L10n.tr(error))
                    } actions: {
                        Button(L10n.tr("重试")) { attempt = UUID() }
                            .accessibilityIdentifier("retryMediaPreview")
                    }
                } else {
                    VStack(spacing: 16) {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                                .frame(maxWidth: 240)
                                .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                        } else { ProgressView() }
                        Text(L10n.tr("正在准备原件…"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(L10n.tr("取消")) { dismiss() }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("preparingMediaPreview")
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成")) { dismiss() }
                        .accessibilityIdentifier("closeMediaPreview")
                }
            }
        }
        .tint(RelayTheme.accent)
        .task(id: attempt) { await model.load(request, package: package) }
        .onDisappear { model.release() }
    }
}

@MainActor
private final class AlbumMediaPreviewModel: ObservableObject {
    @Published private(set) var lease: AlbumMediaPreviewLease?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private let service = AlbumMediaPreviewService()
    private var generation = UUID()

    func load(_ request: AlbumMediaPreviewRequest, package: PackageController) async {
        let token = UUID()
        generation = token; lease = nil; progress = nil; error = nil
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.progress = value.isFinite ? min(1, max(0, value)) : nil
            }
        }
        do {
            let result: AlbumMediaPreviewLease
            switch request.source {
            case let .sent(job, asset):
                result = try await sent(job, asset: asset, package: package, progress: report)
            case let .received(job, item):
                do { result = try await service.received(job, item: item, progress: report) }
                catch {
                    try Task.checkCancellation()
                    guard let identifier = item.assetIdentifier else { throw error }
                    result = try await service.photo(identifier: identifier, kind: item.kind, progress: report)
                }
            }
            guard !Task.isCancelled, generation == token else { result.close(); return }
            guard QLPreviewController.canPreview(result.url as NSURL) else {
                result.close(); throw AlbumMediaPreviewError.unsupported
            }
            lease = result; progress = nil
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription; progress = nil
        }
    }

    private func sent(_ job: PackageJob, asset: PackageAsset, package: PackageController,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> AlbumMediaPreviewLease {
        // A pending private picker source is not a readable original yet.
        if let source = asset.fileSource, asset.pickerResourcePending != true {
            do { return try await service.file(source) }
            catch { try Task.checkCancellation() }
        }
        if job.phase == .ready || asset.reuseSourcePackageID != nil {
            do {
                let original = try await package.resolvePreviewArchive(packageID: job.id, assetID: asset.id)
                return try await service.sentArchive(original.url, asset: original.asset, progress: progress)
            } catch { try Task.checkCancellation() }
        }
        do { return try await service.photo(identifier: asset.assetIdentifier, kind: asset.kind, progress: progress) }
        catch {
            try Task.checkCancellation()
            if package.isBusy && package.job?.id == job.id { throw AlbumMediaPreviewError.busy }
            throw error
        }
    }

    func release() {
        generation = UUID()
        // The native controller also retains the lease until dismantle, so the
        // file remains available throughout the sheet's dismissal animation.
        lease = nil
    }
}

private struct NativeAlbumMediaPreview: UIViewControllerRepresentable {
    let lease: AlbumMediaPreviewLease
    let title: String
    func makeCoordinator() -> Coordinator { Coordinator(lease: lease, title: title) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        controller.dataSource = nil; controller.delegate = nil
        coordinator.lease.close()
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let lease: AlbumMediaPreviewLease
        let item: Item
        init(lease: AlbumMediaPreviewLease, title: String) {
            self.lease = lease; item = Item(url: lease.url, title: title)
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
        func previewController(_ controller: QLPreviewController,
                               editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }
    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
    }
}
