import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum AppDistribution: Equatable, Sendable {
    case development, testFlight, appStore, unknown

    public enum VerifiedTransactionEnvironment: Sendable {
        case production, sandbox, xcode
    }

    public static func detect(isDebug: Bool, receiptName: String?, receiptExists: Bool,
                              verifiedEnvironment: VerifiedTransactionEnvironment? = nil) -> Self {
        if isDebug { return .development }
        switch verifiedEnvironment {
        case .production: return .appStore
        case .sandbox: return .testFlight
        case .xcode: return .development
        case nil: break
        }
        // A sandbox receipt URL identifies the beta channel even when StoreKit
        // has not yet materialized the receipt. Do not mistake that for retail.
        if receiptName == "sandboxReceipt" { return .testFlight }
        guard receiptExists else { return .unknown }
        if receiptName == "receipt" { return .appStore }
        return .unknown
    }
}

public enum TestFlightUpdate {
    // Apple's supported public link opens this app's TestFlight page, including
    // Update/Open for existing testers. A generic itms-beta:// loses the app.
    public static let appURL = URL(string: "https://testflight.apple.com/join/yjrwM4vT")!
}

/// App Store marketing versions are dot-separated integers. Compare components
/// numerically (1.10 > 1.9), and treat omitted trailing zeroes as equivalent.
public struct AppVersionNumber: Comparable, Equatable, Sendable {
    private let components: [UInt64]

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = parts.compactMap { UInt64($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public enum AppStoreLookupError: Error, Equatable {
    case invalidResponse, invalidInstalledVersion
}

public enum AppStoreLookupResult: Equatable, Sendable {
    case notListed, noNewerVersion, updateAvailable(String)
}

public enum AppStoreLookup {
    public static let appID = 6_822_189_862
    public static let appURL = URL(string: "https://apps.apple.com/app/id6822189862")!

    public static func url(countryCode: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        let country = countryCode.uppercased()
        let validCountry = country.utf8.count == 2 && country.utf8.allSatisfy { (65...90).contains($0) }
        components.queryItems = [.init(name: "id", value: String(appID)),
                                 .init(name: "country", value: validCountry ? country : "US"),
                                 .init(name: "entity", value: "software")]
        return components.url!
    }

    public static func evaluate(data: Data, installedVersion: String, bundleIdentifier: String) throws -> AppStoreLookupResult {
        guard let installed = AppVersionNumber(installedVersion) else { throw AppStoreLookupError.invalidInstalledVersion }
        let response: LookupResponse
        do { response = try JSONDecoder().decode(LookupResponse.self, from: data) }
        catch { throw AppStoreLookupError.invalidResponse }
        guard response.resultCount == response.results.count else { throw AppStoreLookupError.invalidResponse }
        if response.resultCount == 0 { return .notListed }
        guard let app = response.results.first(where: { $0.trackId == appID && $0.bundleId == bundleIdentifier }),
              let remote = AppVersionNumber(app.version) else { throw AppStoreLookupError.invalidResponse }
        return remote > installed ? .updateAvailable(app.version) : .noNewerVersion
    }

    private struct LookupResponse: Decodable { var resultCount: Int; var results: [Application] }
    private struct Application: Decodable { var trackId: Int; var bundleId: String; var version: String }
}
