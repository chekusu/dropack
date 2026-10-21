import Combine
import Foundation
import StoreKit

struct InstalledAppVersion: Sendable {
    let version: String
    let build: String
    let bundleIdentifier: String
    let distribution: AppDistribution
    var display: String { "\(version) (\(build))" }

    static func current(bundle: Bundle = .main) -> Self {
#if DEBUG || targetEnvironment(simulator)
        let isDebug = true
#else
        let isDebug = false
#endif
        let receipt = bundle.appStoreReceiptURL
        return Self(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                    build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
                    bundleIdentifier: bundle.bundleIdentifier ?? "",
                    distribution: .detect(isDebug: isDebug, receiptName: receipt?.lastPathComponent,
                        receiptExists: receipt.map { FileManager.default.fileExists(atPath: $0.path) } ?? false))
    }

    /// Called only after the user requests an update check, never when Settings
    /// opens. Do not refresh receipts/transactions or prompt for a Store login.
    static func resolvedDistribution(bundle: Bundle = .main) async -> AppDistribution {
        let local = current(bundle: bundle).distribution
        guard local == .unknown else { return local }
        do {
            let result = try await AppTransaction.shared
            guard case .verified(let transaction) = result,
                  transaction.bundleID == bundle.bundleIdentifier else { return .unknown }
            let environment: AppDistribution.VerifiedTransactionEnvironment?
            switch transaction.environment {
            case .production: environment = .production
            case .sandbox: environment = .sandbox
            case .xcode: environment = .xcode
            default: environment = nil
            }
            return .detect(isDebug: false, receiptName: nil, receiptExists: false,
                           verifiedEnvironment: environment)
        } catch { return .unknown }
    }
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, testFlight, development, noNewerVersion, notListed
        case updateAvailable(String), failed, timedOut, versionUnavailable
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var distribution: AppDistribution
    let installed: InstalledAppVersion
    private let session: URLSession
    private let distributionResolver: () async -> AppDistribution
    private let distributionResolutionTimeout: Duration

    init(installed: InstalledAppVersion = .current(), session: URLSession? = nil,
         distributionResolver: (() async -> AppDistribution)? = nil,
         distributionResolutionTimeout: Duration = .seconds(5)) {
        self.installed = installed
        distribution = installed.distribution
        self.distributionResolver = distributionResolver ?? { await InstalledAppVersion.resolvedDistribution() }
        self.distributionResolutionTimeout = distributionResolutionTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        if distribution == .unknown { distribution = await resolveDistribution() }
        guard !Task.isCancelled else { state = .idle; return }
        // TestFlight availability is per tester/group. Public Store lookup cannot
        // establish whether this tester has the latest beta build.
        switch distribution {
        case .testFlight: state = .testFlight; return
        case .development: state = .development; return
        case .unknown: state = .failed; return
        case .appStore: break
        }
        guard AppVersionNumber(installed.version) != nil, !installed.bundleIdentifier.isEmpty else {
            state = .versionUnavailable; return
        }
        do {
            let country = Locale.autoupdatingCurrent.region?.identifier ?? "US"
            var request = URLRequest(url: AppStoreLookup.url(countryCode: country))
            request.timeoutInterval = 12
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576 else {
                throw AppStoreLookupError.invalidResponse
            }
            switch try AppStoreLookup.evaluate(data: data, installedVersion: installed.version,
                                              bundleIdentifier: installed.bundleIdentifier) {
            case .notListed: state = .notListed
            case .noNewerVersion: state = .noNewerVersion
            case .updateAvailable(let version): state = .updateAvailable(version)
            }
        } catch is CancellationError { state = .idle }
        catch let error as URLError where error.code == .cancelled { state = .idle }
        catch let error as URLError where error.code == .timedOut { state = .timedOut }
        catch { state = .failed }
    }

    private func resolveDistribution() async -> AppDistribution {
        // StoreKit may need the network. Keep the button recoverable even if its
        // async getter does not promptly honor cancellation. Only the first
        // result is accepted; a late response cannot change the visible route.
        let (stream, continuation) = AsyncStream<AppDistribution>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let lookup = Task { [distributionResolver] in
            continuation.yield(await distributionResolver())
            continuation.finish()
        }
        let timeout = Task { [distributionResolutionTimeout] in
            do { try await Task.sleep(for: distributionResolutionTimeout) }
            catch { return }
            continuation.yield(.unknown)
            continuation.finish()
        }
        defer { lookup.cancel(); timeout.cancel(); continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .unknown
    }
}
