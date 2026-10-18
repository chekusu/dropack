import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DropackLiveActivityBundle: WidgetBundle {
    var body: some Widget { DropackTransferLiveActivity() }
}

struct DropackTransferLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            TransferLockScreenView(context: context)
                .environment(\.locale, Locale(identifier: context.language))
                .environment(\.layoutDirection, context.language == "ar" ? .rightToLeft : .leftToRight)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        TransferProgressGlyph(context: context, size: 25, accent: TransferPalette.island)
                        Text("Dropack")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TransferCount(state: context.state, compact: false)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(context.statusLabel)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(TransferPalette.island)
                            Spacer(minLength: 8)
                            Text(context.attributes.kind.title(language: context.language))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        TransferProgressIndicator(state: context.state, accent: TransferPalette.island)
                    }
                    .padding(.top, 5)
                    .padding(.bottom, 3)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(context.accessibilitySummary)
                    .environment(\.locale, Locale(identifier: context.language))
                    .environment(\.layoutDirection, context.language == "ar" ? .rightToLeft : .leftToRight)
                }
            } compactLeading: {
                TransferProgressGlyph(context: context, size: 25, accent: TransferPalette.island)
                    .accessibilityLabel(context.accessibilitySummary)
            } compactTrailing: {
                TransferCount(state: context.state, compact: true)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TransferPalette.island)
                    .frame(maxWidth: 64, alignment: .trailing)
            } minimal: {
                // The system's smallest presentation has no text or controls.
                TransferProgressGlyph(context: context, size: 25, accent: TransferPalette.island)
                    .accessibilityLabel(context.accessibilitySummary)
            }
            .keylineTint(TransferPalette.island)
            .widgetURL(context.attributes.deepLink)
        }
    }
}

private enum TransferPalette {
    static let brand = Color(red: 0.055, green: 0.408, blue: 0.388)
    static let island = Color(red: 0.55, green: 0.90, blue: 0.74)
}

private struct TransferLockScreenView: View {
    let context: ActivityViewContext<TransferActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { colorScheme == .dark ? TransferPalette.island : TransferPalette.brand }

    var body: some View {
        HStack(spacing: 14) {
            TransferProgressGlyph(context: context, size: 43, accent: accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dropack · \(context.attributes.kind.title(language: context.language))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(context.statusLabel)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    TransferCount(state: context.state, compact: false)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
                TransferProgressIndicator(state: context.state, accent: accent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .activitySystemActionForegroundColor(accent)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.accessibilitySummary)
        .accessibilityHint(L10n.translate("打开对应任务", language: context.language))
    }
}

private struct TransferCount: View {
    let state: TransferActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(state.readBytesText ?? displayText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if !compact && state.isReadingUnknownTotal {
                Text(displayText)
                    .font(.caption2).monospacedDigit()
                    .lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let language = state.languageCode ?? L10n.resolvedLanguageCode
        let count = state.displayedTotal > 0
                ? L10n.translate("已完成 %@ 项，共 %@ 项", arguments: [String(state.displayedCompleted), String(state.displayedTotal)], language: state.languageCode ?? L10n.resolvedLanguageCode)
                : L10n.translate("正在准备任务", language: language)
        guard let readBytes = state.readBytesText else { return count }
        return "\(L10n.translate("读取当前文件", language: language)) \(readBytes), \(count)"
    }

    private var displayText: String {
        guard state.displayedTotal > 0 else { return "—" }
        // Large batches show the exact completed count in the narrow island.
        // Abbreviating both sides could make 10,000/10,999 look like 1万/1万.
        // Expanded, Lock Screen and VoiceOver always retain the exact total.
        if compact && state.displayedTotal >= 10_000 { return String(state.displayedCompleted) }
        return "\(state.displayedCompleted)/\(state.displayedTotal)"
    }
}

private struct TransferProgressIndicator: View {
    let state: TransferActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        Group {
            if state.isReadingUnknownTotal {
                // Unknown source size: actual bytes above, no invented fill ratio.
                ProgressView().controlSize(.mini).tint(accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TransferProgressBar(progress: state.progress, accent: accent)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

private struct TransferProgressBar: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.18))
                Capsule().fill(accent)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct TransferProgressGlyph: View {
    let context: ActivityViewContext<TransferActivityAttributes>
    let size: CGFloat
    let accent: Color

    private var symbol: String {
        if context.isStale && context.state.stage == .running { return "clock" }
        if context.state.isReadingUnknownTotal { return "arrow.down" }
        switch context.state.stage {
        case .running: return context.attributes.kind == .packaging ? "shippingbox" : "photo.on.rectangle"
        case .paused: return "pause.fill"
        case .finished: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.22), lineWidth: 2)
            if !context.state.isReadingUnknownTotal {
                Circle().trim(from: 0, to: context.state.progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(accent)
        }
        .padding(2)
        .frame(width: size, height: size)
    }
}

private extension ActivityViewContext where Attributes == TransferActivityAttributes {
    var language: String { state.languageCode ?? L10n.resolvedLanguageCode }
    var statusLabel: String {
        isStale && state.stage == .running ? L10n.translate("进度待更新", language: language) : state.statusLabel(for: attributes.kind)
    }

    var accessibilitySummary: String {
        let count = state.displayedTotal > 0
            ? L10n.translate("已完成 %@ 项，共 %@ 项", arguments: [String(state.displayedCompleted), String(state.displayedTotal)], language: language)
            : L10n.translate("正在准备任务", language: language)
        let resource = state.readBytesText.map { "，\($0)" } ?? ""
        return "Dropack，\(attributes.kind.title(language: language))，\(statusLabel)\(resource)，\(count)"
    }
}
