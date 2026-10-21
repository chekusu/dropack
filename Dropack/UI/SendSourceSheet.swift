import SwiftUI

enum SendSourceChoice { case photos, files }

/// A native sheet also on iPad, with one presentation hand-off after dismissal.
struct SendSourceSheet: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    var onChoose: (SendSourceChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                source(.photos, title: L10n.tr("相册"), subtitle: L10n.tr("照片与视频"), symbol: "photo.on.rectangle",
                       identifier: "sendSourcePhotos")
                source(.files, title: L10n.tr("文件"), subtitle: L10n.tr("iCloud、U 盘或本机文件"), symbol: "folder",
                       identifier: "sendSourceFiles")
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.tr("从哪里选择"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) { dismiss() }.accessibilityIdentifier("cancelSendSources")
                }
            }
        }
        .tint(RelayTheme.accent)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(310), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .accessibilityIdentifier("sendSourceSheet")
    }

    private func source(_ choice: SendSourceChoice, title: String, subtitle: String,
                        symbol: String, identifier: String) -> some View {
        Button { onChoose(choice) } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(RelayTheme.accent)
                    .background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
