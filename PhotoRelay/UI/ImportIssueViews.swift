import SwiftUI

enum IssueKind: String { case failed, uncertain }

struct IssueListView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    let kind: IssueKind
    @Environment(\.dismiss) private var dismiss

    private var items: [ImportItem] {
        controller.job?.items.filter { $0.state == (kind == .failed ? .failed : .uncertain) } ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView(L10n.tr("已处理完毕"), systemImage: "checkmark.circle", description: Text(L10n.tr("这里没有需要处理的项目。")))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(items) { item in
                            if kind == .uncertain {
                                UncertainItemRow(controller: controller, item: item)
                                    .padding(.vertical, 6)
                            } else {
                                FailureItemRow(item: item).padding(.vertical, 6)
                            }
                        }
                    } header: {
                        Text(kind == .uncertain ? L10n.tr("请先在相册逐个核对，再选择处理方式。") : L10n.tr("查看原因并处理后，可以把失败项目重新加入队列。"))
                    }
                    if kind == .failed {
                        Section {
                            Button(L10n.tr("重试全部失败项目")) { controller.retryFailures() }
                                .disabled(controller.isBusy || controller.isPreparing || controller.requiresReset)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RelayTheme.background)
            .navigationTitle(kind == .uncertain ? L10n.tr("待确认项目") : L10n.tr("失败项目"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("完成")) { dismiss() } } }
        }
        .tint(RelayTheme.accent)
    }
}

struct FailureItemRow: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    let item: ImportItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label((item.relativePath as NSString).lastPathComponent, systemImage: item.kind == .photo ? "photo" : "video")
                .font(.subheadline.weight(.medium)).lineLimit(2).truncationMode(.middle)
            Text(item.relativePath).font(.caption2).foregroundStyle(RelayTheme.secondary)
                .lineLimit(2).truncationMode(.middle)
            Text(L10n.tr(item.errorMessage ?? L10n.tr("保存失败，请重试。")))
                .font(.caption).foregroundStyle(RelayTheme.warning).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UncertainItemRow: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    let item: ImportItem
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label((item.relativePath as NSString).lastPathComponent, systemImage: item.kind == .photo ? "photo" : "video")
                .font(.subheadline.weight(.medium)).lineLimit(2).truncationMode(.middle)
            Text(item.relativePath).font(.caption2).foregroundStyle(RelayTheme.secondary)
                .lineLimit(2).truncationMode(.middle)
            Button(L10n.tr("核对后处理")) { showConfirmation = true }
                .font(.caption.weight(.semibold))
                .disabled(controller.isBusy || controller.isPreparing || controller.requiresReset)
                .confirmationDialog(L10n.tr("请先在相册确认这个文件"), isPresented: $showConfirmation, titleVisibility: .visible) {
                    Button(L10n.tr("已在相册确认，标记为已保存")) { controller.resolveUncertain(id: item.id, asSaved: true) }
                    Button(L10n.tr("重新导入，可能产生重复项"), role: .destructive) { controller.resolveUncertain(id: item.id, asSaved: false) }
                    Button(L10n.tr("稍后处理"), role: .cancel) {}
                } message: {
                    Text(L10n.tr("%@\n\n如果它已在相册中，请标记为已保存。无法确认时可以重新导入，但可能产生重复项。", String(describing: item.relativePath)))
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
