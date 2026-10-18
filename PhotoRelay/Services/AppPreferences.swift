import Combine
import Foundation
import SwiftUI

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    static let sharingNameByteLimit = ShareAlbumMetadata.maximumSenderNameUTF8Bytes
    private let defaults: UserDefaults
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "dropack.appearance") }
    }
    @Published var language: String {
        didSet {
            defaults.set(language, forKey: "dropack.language")
            L10n.languageCode = language
        }
    }
    @Published var sharingName: String {
        didSet {
            let editable = ShareAlbumNaming.senderNameInput(sharingName)
            if editable != sharingName { sharingName = editable }
            defaults.set(Self.sanitizedSharingName(editable), forKey: "dropack.sharingName")
        }
    }

    static func sanitizedSharingName(_ value: String) -> String {
        ShareAlbumNaming.senderName(deviceName: value) ?? ""
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "dropack.appearance") ?? "") ?? .system
        let savedLanguage = defaults.string(forKey: "dropack.language") ?? "system"
        language = L10n.supportedLanguages.contains { $0.code == savedLanguage } ? savedLanguage : "system"
        sharingName = Self.sanitizedSharingName(defaults.string(forKey: "dropack.sharingName") ?? "")
        L10n.languageCode = language
    }

    var locale: Locale { L10n.locale }
    var layoutDirection: LayoutDirection { L10n.isRightToLeft ? .rightToLeft : .leftToRight }
    var preferredColorScheme: ColorScheme? {
        switch theme { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
