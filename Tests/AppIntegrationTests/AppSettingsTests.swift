import XCTest
@testable import Dropack

@MainActor
final class AppSettingsTests: XCTestCase {
    func testThemeAndLanguagePreferencesPersistAndResolvePresentation() throws {
        let suite = "dropack-settings-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalLanguage = L10n.languageCode
        defer { defaults.removePersistentDomain(forName: suite); L10n.languageCode = originalLanguage }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.language, "system")
        preferences.theme = .dark; preferences.language = "ar"
        XCTAssertEqual(preferences.preferredColorScheme, .dark)
        XCTAssertEqual(preferences.layoutDirection, .rightToLeft)
        let reopened = AppPreferences(defaults: defaults)
        XCTAssertEqual(reopened.theme, .dark)
        XCTAssertEqual(reopened.language, "ar")
        reopened.theme = .system
        XCTAssertNil(reopened.preferredColorScheme)
    }

    func testBetaAndDevelopmentChecksNeverUsePublicLookup() async {
        for (distribution, expected) in [(AppDistribution.testFlight, AppUpdateChecker.State.testFlight), (.development, .development)] {
            let checker = AppUpdateChecker(installed: installed(distribution), session: session(mode: "unreachable"))
            await checker.check()
            XCTAssertEqual(checker.state, expected)
        }
    }

    func testMissingReceiptBetaResolvesToTestFlightWithoutAppStoreLookup() async {
        let checker = AppUpdateChecker(installed: installed(.unknown), session: session(mode: "unreachable"),
                                       distributionResolver: { .testFlight })
        await checker.check()
        XCTAssertEqual(checker.distribution, .testFlight)
        XCTAssertEqual(checker.state, .testFlight)
    }

    func testUnresolvedChannelNeverSilentlyChecksTheRetailVersion() async {
        let checker = AppUpdateChecker(installed: installed(.unknown), session: session(mode: "unreachable"),
                                       distributionResolver: { .unknown })
        await checker.check()
        XCTAssertEqual(checker.distribution, .unknown)
        XCTAssertEqual(checker.state, .failed)
    }

    func testKnownChannelDoesNotContactStoreKitAndVerifiedRetailCanLookUpUpdates() async {
        let knownBeta = AppUpdateChecker(installed: installed(.testFlight), session: session(mode: "unreachable"),
            distributionResolver: { XCTFail("A known beta must not request a transaction"); return .unknown })
        await knownBeta.check()
        XCTAssertEqual(knownBeta.state, .testFlight)
        let retail = AppUpdateChecker(installed: installed(.unknown), session: session(mode: "newer"),
                                      distributionResolver: { .appStore })
        await retail.check()
        XCTAssertEqual(retail.state, .updateAvailable("1.10"))
    }

    func testStoreKitTimeoutAllowsManualChannelChoiceWithoutAnAppStoreLookup() async {
        let checker = AppUpdateChecker(installed: installed(.unknown), session: session(mode: "unreachable"),
            distributionResolver: {
                try? await Task.sleep(for: .seconds(60))
                return .testFlight
            }, distributionResolutionTimeout: .milliseconds(10))
        await checker.check()
        XCTAssertEqual(checker.distribution, .unknown)
        XCTAssertEqual(checker.state, .failed)
        // A cancelled, late StoreKit result must not change the chosen route.
        await Task.yield()
        XCTAssertEqual(checker.distribution, .unknown)
    }

    func testSharingNamePersistsSafelyAndAllowsTypingSpaces() throws {
        let suite = "dropack-sharing-name-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalLanguage = L10n.languageCode
        defer { defaults.removePersistentDomain(forName: suite); L10n.languageCode = originalLanguage }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.sharingName, "")
        preferences.sharingName = "小雨 "
        XCTAssertEqual(preferences.sharingName, "小雨 ", "A text field must allow the next word to be entered")
        preferences.sharingName += "的 iPhone\n\u{202E}"
        XCTAssertFalse(preferences.sharingName.contains("\n"))
        XCTAssertFalse(preferences.sharingName.contains("\u{202E}"))
        XCTAssertEqual(defaults.string(forKey: "dropack.sharingName"), "小雨 的 iPhone")
        XCTAssertEqual(AppPreferences(defaults: defaults).sharingName, "小雨 的 iPhone")
        preferences.sharingName = String(repeating: "👩🏽‍💻", count: 100)
        XCTAssertLessThanOrEqual(preferences.sharingName.utf8.count, AppPreferences.sharingNameByteLimit)
        XCTAssertTrue(preferences.sharingName.allSatisfy { String($0) == "👩🏽‍💻" })
        preferences.sharingName = " \n\t "
        XCTAssertEqual(AppPreferences.sanitizedSharingName(preferences.sharingName), "")
        XCTAssertEqual(AppPreferences(defaults: defaults).sharingName, "")
    }

    func testStoreLookupEmptyIsNotListedAndErrorNeverClaimsLatest() async {
        let empty = AppUpdateChecker(installed: installed(.appStore), session: session(mode: "empty"))
        await empty.check(); XCTAssertEqual(empty.state, .notListed)
        let failed = AppUpdateChecker(installed: installed(.appStore), session: session(mode: "server-error"))
        await failed.check(); XCTAssertEqual(failed.state, .failed)
        let timeout = AppUpdateChecker(installed: installed(.appStore), session: session(mode: "timeout"))
        await timeout.check(); XCTAssertEqual(timeout.state, .timedOut)
    }

    func testStoreLookupReportsMatchingNewerVersion() async {
        let checker = AppUpdateChecker(installed: installed(.appStore), session: session(mode: "newer"))
        await checker.check()
        XCTAssertEqual(checker.state, .updateAvailable("1.10"))
        XCTAssertEqual(checker.installed.display, "1.9 (42)")
    }

    private func installed(_ distribution: AppDistribution) -> InstalledAppVersion {
        .init(version: "1.9", build: "42", bundleIdentifier: "app.dropack.ios", distribution: distribution)
    }

    private func session(mode: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateLookupFixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-Dropack-Test-Mode": mode]
        return URLSession(configuration: config)
    }
}

private final class UpdateLookupFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "X-Dropack-Test-Mode") ?? "unreachable"
        if mode == "unreachable" { XCTFail("This distribution must not use the public App Store lookup") }
        if mode == "timeout" || mode == "unreachable" {
            client?.urlProtocol(self, didFailWithError: URLError(mode == "timeout" ? .timedOut : .cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "server-error" ? 503 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = mode == "newer"
            ? #"{"resultCount":1,"results":[{"trackId":6822189862,"bundleId":"app.dropack.ios","version":"1.10"}]}"#
            : #"{"resultCount":0,"results":[]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(data.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
