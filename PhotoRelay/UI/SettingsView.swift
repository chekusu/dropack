import SwiftUI

@MainActor
struct SettingsView: View {
    var onHelp: (() -> Void)? = nil
    @ObservedObject private var preferences = AppPreferences.shared
    @StateObject private var updates = AppUpdateChecker()
    @State private var showingHelp = false
    @State private var updateTask: Task<Void, Never>?
    @State private var testFlightOpenFailed = false
    @State private var editingSharingName = false
    @State private var sharingNameDraft = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Button {
                    sharingNameDraft = preferences.sharingName
                    editingSharingName = true
                } label: {
                    LabeledContent(L10n.tr("分享名称"),
                        value: preferences.sharingName.isEmpty ? L10n.tr("设备名称") : preferences.sharingName)
                        .foregroundStyle(RelayTheme.ink)
                }
                .accessibilityIdentifier("sharingNameButton")
            } footer: {
                Text(L10n.tr("用于新建分享相册，留空使用设备名称。"))
            }

            Section {
                Picker(L10n.tr("主题"), selection: $preferences.theme) {
                    Text(L10n.tr("跟随系统")).tag(AppTheme.system).accessibilityIdentifier("theme-system")
                    Text(L10n.tr("浅色")).tag(AppTheme.light).accessibilityIdentifier("theme-light")
                    Text(L10n.tr("深色")).tag(AppTheme.dark).accessibilityIdentifier("theme-dark")
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("appearancePicker")
            } header: { Text(L10n.tr("外观")) }

            Section {
                Picker(L10n.tr("语言"), selection: $preferences.language) {
                    Text(L10n.tr("跟随系统")).tag("system").accessibilityIdentifier("language-system")
                    ForEach(L10n.supportedLanguages) { language in
                        Text(language.name).tag(language.code)
                            .accessibilityIdentifier("language-\(language.code)")
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("languagePicker")
            } header: { Text(L10n.tr("语言")) }

            Section {
                LabeledContent(L10n.tr("版本"), value: updates.installed.display)
                    .accessibilityIdentifier("installedAppVersion")
                Button {
                    testFlightOpenFailed = false
                    updateTask = Task {
                        await updates.check()
                        guard !Task.isCancelled else { return }
                        if updates.state == .testFlight { openTestFlight() }
                    }
                } label: {
                    HStack {
                        Text(L10n.tr(updates.distribution == .testFlight ? "在 TestFlight 中检查" : "检查更新"))
                        Spacer()
                        if updates.state == .checking { ProgressView() }
                        else { Image(systemName: "arrow.up.right").font(.footnote) }
                    }
                }
                .disabled(updates.state == .checking)
                .accessibilityIdentifier("checkForUpdatesButton")

                if case .updateAvailable = updates.state {
                    Link(L10n.tr("打开 App Store"), destination: AppStoreLookup.appURL)
                }
                if let text = updateMessage {
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("updateCheckResult")
                }
                if updates.distribution == .unknown, updates.state == .failed {
                    Button(L10n.tr("在 TestFlight 中检查")) { openTestFlight() }
                        .accessibilityIdentifier("checkTestFlightFallbackButton")
                    Link(L10n.tr("打开 App Store"), destination: AppStoreLookup.appURL)
                }
                Button(L10n.tr("使用说明"), systemImage: "questionmark.circle") {
                    if let onHelp { onHelp() } else { showingHelp = true }
                }
                Link(destination: URL(string: "https://dropack.app/privacy/")!) {
                    Label(L10n.tr("隐私政策"), systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://dropack.app/")!) {
                    Label("dropack.app", systemImage: "safari")
                }
            } header: { Text(L10n.tr("关于")) }
              footer: {
                if updates.distribution == .testFlight {
                    Text(L10n.tr("测试版更新由 TestFlight 管理。"))
                } else if updates.distribution == .development {
                    Text(L10n.tr("开发版本"))
                }
            }
        }
        // iOS 18's backing collection view can retain its RTL transform after
        // switching back to LTR. Recreate only this form, preserving the route,
        // settings model and all transfer controllers above it.
        .id(L10n.isRightToLeft)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(L10n.tr("设置"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settingsView")
        .sheet(isPresented: $showingHelp) { HelpView() }
        .alert(L10n.tr("分享名称"), isPresented: $editingSharingName) {
            TextField(L10n.tr("你的名字或设备名称"), text: $sharingNameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button(L10n.tr("保存")) {
                preferences.sharingName = AppPreferences.sanitizedSharingName(sharingNameDraft)
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        }
        .onDisappear { updateTask?.cancel(); updateTask = nil }
    }

    private var updateMessage: String? {
        if testFlightOpenFailed { return L10n.tr("请打开 TestFlight，在 Dropack 页面查看可用版本。") }
        switch updates.state {
        case .idle, .checking: return nil
        case .testFlight: return L10n.tr("请打开 TestFlight，在 Dropack 页面查看可用版本。")
        case .development: return L10n.tr("这是开发版本，请通过开发工具安装更新。")
        case .noNewerVersion: return L10n.tr("所查询地区的 App Store 暂未发现更新版本。")
        case .notListed: return L10n.tr("所查询地区的 App Store 暂未找到 Dropack，无法确认更新。")
        case .updateAvailable(let version): return L10n.tr("发现新版本 %@", version)
        case .failed: return L10n.tr("暂时无法检查更新，请稍后重试。")
        case .timedOut: return L10n.tr("检查更新超时，请重试。")
        case .versionUnavailable: return L10n.tr("无法读取当前版本，请在 App Store 中查看。")
        }
    }

    private func openTestFlight() {
        testFlightOpenFailed = false
        openURL(TestFlightUpdate.appURL) { accepted in
            if !accepted { testFlightOpenFailed = true }
        }
    }
}
