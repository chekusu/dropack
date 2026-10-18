import XCTest
@testable import RelayCore

final class AppUpdatePolicyTests: XCTestCase {
    func testMarketingVersionsCompareNumericallyWithZeroPadding() throws {
        XCTAssertTrue(try XCTUnwrap(AppVersionNumber("1.10")) > XCTUnwrap(AppVersionNumber("1.9.9")))
        XCTAssertEqual(AppVersionNumber("1"), AppVersionNumber("1.0.0"))
        XCTAssertTrue(try XCTUnwrap(AppVersionNumber("2.0")) > XCTUnwrap(AppVersionNumber("1.999.999")))
        for invalid in ["", "1.", "1..2", "v1.0", "1.0-beta", "-1.0", "1.2.3.4", "１.０", "18446744073709551616"] {
            XCTAssertNil(AppVersionNumber(invalid), invalid)
        }
    }

    func testSandboxReceiptPathKeepsBetaChannelEvenBeforeReceiptExists() {
        XCTAssertEqual(AppDistribution.detect(isDebug: true, receiptName: "sandboxReceipt", receiptExists: true), .development)
        XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: "sandboxReceipt", receiptExists: true), .testFlight)
        XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: "sandboxReceipt", receiptExists: false), .testFlight)
        XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: "receipt", receiptExists: true), .appStore)
        XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: "receipt", receiptExists: false), .unknown)
        XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: nil, receiptExists: false), .unknown)
    }

    func testVerifiedStoreKitEnvironmentsResolveMissingReceiptWithoutChangingDebugChannel() {
        for (environment, expected) in [
            (AppDistribution.VerifiedTransactionEnvironment.sandbox, AppDistribution.testFlight),
            (.production, .appStore), (.xcode, .development)
        ] {
            XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: nil, receiptExists: false,
                                                   verifiedEnvironment: environment), expected)
            XCTAssertEqual(AppDistribution.detect(isDebug: true, receiptName: nil, receiptExists: false,
                                                   verifiedEnvironment: environment), .development)
        }
        XCTAssertEqual(AppDistribution.detect(isDebug: false, receiptName: "sandboxReceipt", receiptExists: true,
                                               verifiedEnvironment: .production), .appStore)
    }

    func testOnlyMatchingAppWithValidVersionCanReportUpdate() throws {
        let update = try AppStoreLookup.evaluate(data: response(version: "1.10"), installedVersion: "1.9", bundleIdentifier: "app.dropack.ios")
        XCTAssertEqual(update, .updateAvailable("1.10"))
        XCTAssertEqual(try AppStoreLookup.evaluate(data: response(version: "1.0.0"), installedVersion: "1.0", bundleIdentifier: "app.dropack.ios"), .noNewerVersion)
        XCTAssertEqual(try AppStoreLookup.evaluate(data: response(version: "1.0"), installedVersion: "2.0", bundleIdentifier: "app.dropack.ios"), .noNewerVersion)
        XCTAssertThrowsError(try AppStoreLookup.evaluate(data: response(version: "oops"), installedVersion: "1", bundleIdentifier: "app.dropack.ios"))
        XCTAssertThrowsError(try AppStoreLookup.evaluate(data: response(version: "2.0"), installedVersion: "1", bundleIdentifier: "unrelated.bundle"))
        XCTAssertThrowsError(try AppStoreLookup.evaluate(data: response(version: "2.0", appID: 1), installedVersion: "1", bundleIdentifier: "app.dropack.ios"))
    }

    func testNotListedIsDifferentFromInvalidResponseOrUnknownCurrentVersion() throws {
        let empty = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        XCTAssertEqual(try AppStoreLookup.evaluate(data: empty, installedVersion: "1.0", bundleIdentifier: "app.dropack.ios"), .notListed)
        for bad in [Data(), Data("<html>error</html>".utf8), Data(#"{"resultCount":1,"results":[]}"#.utf8)] {
            XCTAssertThrowsError(try AppStoreLookup.evaluate(data: bad, installedVersion: "1.0", bundleIdentifier: "app.dropack.ios"))
        }
        XCTAssertThrowsError(try AppStoreLookup.evaluate(data: empty, installedVersion: "—", bundleIdentifier: "app.dropack.ios"))
    }

    func testLookupUsesOnlyFixedAppleHostAndValidatedCountry() throws {
        let jp = try XCTUnwrap(URLComponents(url: AppStoreLookup.url(countryCode: "jp"), resolvingAgainstBaseURL: false))
        XCTAssertEqual(jp.host, "itunes.apple.com")
        XCTAssertEqual(jp.queryItems?.first(where: { $0.name == "country" })?.value, "JP")
        XCTAssertEqual(jp.queryItems?.first(where: { $0.name == "id" })?.value, "6822189862")
        let fallback = try XCTUnwrap(URLComponents(url: AppStoreLookup.url(countryCode: "JP&country=CN"), resolvingAgainstBaseURL: false))
        XCTAssertEqual(fallback.queryItems?.first(where: { $0.name == "country" })?.value, "US")
    }

    private func response(version: String, appID: Int = AppStoreLookup.appID) -> Data {
        Data("{\"resultCount\":1,\"results\":[{\"trackId\":\(appID),\"bundleId\":\"app.dropack.ios\",\"version\":\"\(version)\"}]}".utf8)
    }
}
