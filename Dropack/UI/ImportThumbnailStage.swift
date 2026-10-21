import SwiftUI

/// A successful Photos transaction moves the actual thumbnail into the saved stack.
/// This presentation never delays, queues or changes the import transaction itself.
struct ImportThumbnailStage: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @ObservedObject var controller: ImportController
    @ObservedObject private var activity: ImportActivity

    init(controller: ImportController) {
        self.controller = controller
        self.activity = controller.activity
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flying: ImportPreview?
    @State private var landed = false
    @State private var flightTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let sourceX = geometry.size.width * 0.30
                let savedX = geometry.size.width * 0.78
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(RelayTheme.paleAccent)
                        .frame(width: 138, height: 150)
                        .position(x: sourceX, y: 84)
                    preview(controller.activePreview ?? controller.lastSavedPreview, size: 112)
                        .opacity(flying != nil && !reduceMotion ? 0.30 : 1)
                        .position(x: sourceX, y: 80)
                        .accessibilityIdentifier("importCurrentThumbnail")
                        .accessibilityLabel(controller.activePreview.map { L10n.tr("当前素材，%@", String(describing: $0.title)) } ?? L10n.tr("照片预览"))

                    VStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(RelayTheme.accent.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .background(RelayTheme.paleAccent, in: RoundedRectangle(cornerRadius: 16))
                            if controller.recentSavedPreviews.isEmpty {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2).foregroundStyle(RelayTheme.accent.opacity(0.5))
                            }
                            ForEach(Array(controller.recentSavedPreviews.reversed())) { item in
                                let depth = controller.recentSavedPreviews.firstIndex(where: { $0.id == item.id }) ?? 0
                                preview(item, size: 66)
                                    .rotationEffect(.degrees(Double(depth) * -6))
                                    .offset(x: CGFloat(depth) * -4, y: CGFloat(depth) * -3)
                            }
                        }.frame(width: 78, height: 78)
                        Group {
                            if (controller.job?.savedCount ?? 0) > 0 {
                                Label(L10n.tr("已存相册"), systemImage: "checkmark")
                            } else {
                                Text(L10n.tr("相册"))
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RelayTheme.accent)
                    }
                    .position(x: savedX, y: 93)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.tr("相册保存进度"))
                    .accessibilityValue(L10n.tr("已保存 %@ 项", String(describing: controller.job?.savedCount ?? 0)))
                    .accessibilityIdentifier("importSavedFeedback")

                    if let flying, !reduceMotion {
                        preview(flying, size: 112)
                            .scaleEffect(landed ? 0.59 : 1)
                            .rotationEffect(.degrees(landed ? -4 : 0))
                            .opacity(landed ? 0.1 : 1)
                            .position(x: sourceX, y: 80)
                            .offset(x: landed ? savedX - sourceX : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }.frame(height: 170)
            if let item = controller.activePreview ?? controller.lastSavedPreview {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .video ? "video" : "photo")
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                }.font(.caption).foregroundStyle(RelayTheme.secondary)
            }
        }
        .onChange(of: controller.savedPreviewSequence) { _, _ in animateSaved() }
        .onChange(of: controller.job?.id) { _, _ in resetFlight() }
        .onChange(of: reduceMotion) { _, _ in resetFlight() }
        .onDisappear { resetFlight() }
    }

    @ViewBuilder
    private func preview(_ item: ImportPreview?, size: CGFloat) -> some View {
        Group {
            if let image = item?.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    RelayTheme.surface
                    Image(systemName: item?.kind == .video ? "video" : "photo")
                        .font(.system(size: size * 0.30, weight: .light))
                        .foregroundStyle(RelayTheme.accent.opacity(0.65))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.13))
        .overlay(RoundedRectangle(cornerRadius: size * 0.13).strokeBorder(.white.opacity(0.6), lineWidth: 2))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 3)
    }

    private func animateSaved() {
        resetFlight()
        guard !reduceMotion, let preview = controller.lastSavedPreview else { return }
        flying = preview
        flightTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.44)) { landed = true }
            try? await Task.sleep(for: .milliseconds(480))
            guard !Task.isCancelled else { return }
            flying = nil
        }
    }

    private func resetFlight() {
        flightTask?.cancel()
        flightTask = nil
        flying = nil
        landed = false
    }
}
