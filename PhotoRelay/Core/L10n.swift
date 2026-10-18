import Foundation

public struct AppLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }
}

/// A language change only changes presentation. Durable stages, history, source
/// filenames and album titles stay intact. Both executables read this catalog.
public enum L10n {
    public static let preferenceKey = "dropack.language"
    public static let supportedLanguages: [AppLanguage] = [
        .init(code: "en", name: "English"), .init(code: "zh-Hans", name: "简体中文"),
        .init(code: "zh-Hant", name: "繁體中文"), .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"), .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"), .init(code: "de", name: "Deutsch"),
        .init(code: "it", name: "Italiano"), .init(code: "pt-BR", name: "Português (Brasil)"),
        .init(code: "nl", name: "Nederlands"), .init(code: "pl", name: "Polski"),
        .init(code: "tr", name: "Türkçe"), .init(code: "ar", name: "العربية"),
        .init(code: "hi", name: "हिन्दी"), .init(code: "id", name: "Bahasa Indonesia")
    ]
    public static var languageCode: String {
        get { UserDefaults.standard.string(forKey: preferenceKey) ?? "system" }
        set { UserDefaults.standard.set(newValue == "system" ? "system" : resolve(newValue), forKey: preferenceKey) }
    }
    public static var resolvedLanguageCode: String {
        languageCode == "system"
            ? resolve(Bundle.preferredLocalizations(from: supportedLanguages.map(\.code), forPreferences: Locale.preferredLanguages).first ?? "en")
            : resolve(languageCode)
    }
    public static var locale: Locale { Locale(identifier: resolvedLanguageCode) }
    public static var isRightToLeft: Bool { resolvedLanguageCode == "ar" }
    public static func resolve(_ requested: String) -> String {
        let value = requested.replacingOccurrences(of: "_", with: "-")
        if supportedLanguages.contains(where: { $0.code == value }) { return value }
        let lower = value.lowercased()
        if lower.hasPrefix("zh") { return lower.contains("hant") || lower.contains("tw") || lower.contains("hk") || lower.contains("mo") ? "zh-Hant" : "zh-Hans" }
        if lower.hasPrefix("pt") { return "pt-BR" }
        return supportedLanguages.first(where: { lower == $0.code.lowercased() || lower.hasPrefix($0.code.lowercased() + "-") })?.code ?? "en"
    }

    public static func tr(_ source: String, _ arguments: String...) -> String {
        translate(source, arguments: arguments, language: resolvedLanguageCode)
    }
    /// Explicit language is also used by a Live Activity: its payload captures
    /// the app language without sharing private defaults or task content.
    public static func translate(_ source: String, arguments: [String] = [], language: String) -> String {
        localized(source, arguments: arguments, language: resolve(language), depth: 0)
    }

    private static let catalog: [String: [String: String]] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    private struct Template {
        let key: String
        let expression: NSRegularExpression
        let weight: Int
    }
    private static let templates: [Template] = (catalog["en"] ?? [:]).keys.compactMap { key in
        guard key.contains("%@") else { return nil }
        let pieces = key.components(separatedBy: "%@")
        let expression = "^" + pieces.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
        return Template(key: key, expression: regex, weight: pieces.joined().count)
    }.sorted { $0.weight > $1.weight }

    private static func localized(_ source: String, arguments: [String], language: String, depth: Int) -> String {
        guard depth < 6 else { return source }
        if let value = catalog[language]?[source] ?? catalog["en"]?[source] {
            return format(value, arguments: arguments)
        }
        // Older checkpoints contain interpolated Chinese messages. Decode only
        // known source templates; arbitrary filenames and user titles are untouched.
        if arguments.isEmpty, source.range(of: "[\\p{Han}]", options: .regularExpression) != nil {
            let range = NSRange(source.startIndex..., in: source)
            for template in templates {
                guard let match = template.expression.firstMatch(in: source, range: range) else { continue }
                let values = (1..<match.numberOfRanges).map { index -> String in
                    guard let range = Range(match.range(at: index), in: source) else { return "" }
                    return String(source[range])
                }
                // Only diagnostic wrappers nest app messages. Quoted file paths,
                // album titles, and ordinary values remain exactly as recorded.
                let isDiagnostic = (template.key.contains("无法") || template.key.contains("失败") || template.key.hasPrefix("分享未完成"))
                    && !template.key.contains("“%@")
                let arguments = isDiagnostic
                    ? values.map { localized($0, arguments: [], language: language, depth: depth + 1) }
                    : values
                return localized(template.key, arguments: arguments, language: language, depth: depth + 1)
            }
        }
        return format(source, arguments: arguments)
    }
    private static func format(_ template: String, arguments: [String]) -> String {
        let pieces = template.components(separatedBy: "%@")
        guard pieces.count > 1, pieces.count - 1 == arguments.count else { return template }
        return zip(arguments, pieces.dropFirst()).reduce(pieces[0]) { $0 + $1.0 + $1.1 }
    }
}
