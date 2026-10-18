import CryptoKit
import Foundation
import Photos
import XCTest
@testable import Dropack

final class PackageOriginalProgressIntegrationTests: XCTestCase {
    func testLocalSuccessReadsOnceWithoutNetworkOrCloudClaim() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("original.mov")
        let bytes = Data("local original bytes".utf8)
        var attempts: [Bool] = []
        let cloud = OriginalTestReports()
        let result = try await PhotoResourceLocalFirst.export(destination: destination, safetyMargin: 0,
            onNetworkRequired: { cloud.recordCloud() }) { stream, network in
            attempts.append(network)
            return try await stream.export { receive, finish in
                receive(bytes); finish(nil); return {}
            }
        }
        XCTAssertEqual(attempts, [false])
        XCTAssertEqual(cloud.cloudEvents, 0)
        XCTAssertEqual(result.byteCount, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testOnlyExactNetworkRequiredRetriesAndTruncatesPartialLocalBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("original.mov")
        let bytes = Data("complete remote original".utf8)
        var attempts: [Bool] = []
        let cloud = OriginalTestReports()
        let stale = OriginalStreamCallbacks()
        let result = try await PhotoResourceLocalFirst.export(destination: destination, safetyMargin: 0,
            onNetworkRequired: { cloud.recordCloud() }) { stream, network in
            attempts.append(network)
            return try await stream.export { receive, finish in
                if !network {
                    stale.register(receive: receive, completion: finish)
                    receive(Data("partial old local prefix".utf8))
                    finish(NSError(domain: PHPhotosErrorDomain,
                        code: PHPhotosError.Code.networkAccessRequired.rawValue))
                } else {
                    receive(bytes); finish(nil)
                }
                return {}
            }
        }
        XCTAssertEqual(attempts, [false, true])
        XCTAssertEqual(cloud.cloudEvents, 1)
        XCTAssertEqual(result.byteCount, UInt64(bytes.count))
        XCTAssertEqual(result.hash, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        stale.send(Data("late stale local data".utf8)); stale.finish(nil)
        XCTAssertEqual(try Data(contentsOf: destination), bytes, "Retry must replace partial local bytes, never append them.")
    }

    func testOtherErrorsAndCancellationNeverRequestNetwork() async throws {
        let errors: [Error] = [
            NSError(domain: "another.domain", code: PHPhotosError.Code.networkAccessRequired.rawValue),
            NSError(domain: PHPhotosErrorDomain, code: 1234),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            CancellationError()
        ]
        for error in errors {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var attempts: [Bool] = []
            let cloud = OriginalTestReports()
            do {
                _ = try await PhotoResourceLocalFirst.export(destination: root.appendingPathComponent("original.mov"),
                    safetyMargin: 0, onNetworkRequired: { cloud.recordCloud() }) { stream, network in
                    attempts.append(network)
                    return try await stream.export { _, finish in finish(error); return {} }
                }
                XCTFail("The original error must propagate")
            } catch {}
            XCTAssertEqual(attempts, [false])
            XCTAssertEqual(cloud.cloudEvents, 0)
        }
    }

    func testCancellationBeforeCloudRetryWinsOverNetworkRequiredError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = OriginalTestReports()
        let task = Task {
            try await PhotoResourceLocalFirst.export(destination: root.appendingPathComponent("original.mov"),
                safetyMargin: 0, onNetworkRequired: { cloud.recordCloud() }) { stream, network in
                XCTAssertFalse(network)
                return try await stream.export { _, finish in
                    withUnsafeCurrentTask { $0?.cancel() }
                    finish(NSError(domain: PHPhotosErrorDomain,
                        code: PHPhotosError.Code.networkAccessRequired.rawValue))
                    return {}
                }
            }
        }
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cloud.cloudEvents, 0)
    }

    func testLivePhotoLocalStillNeverManufacturesCloudVideoPercentageOrEarlyReady() {
        let tracker = PackageOriginalProgressTracker(resourceCount: 2)
        tracker.report(resource: 0, fraction: 1) { XCTAssertEqual($0.state, .preparing) }
        tracker.report(resource: 0, completed: true) { XCTAssertEqual($0.state, .preparing) }
        tracker.report(resource: 1, cloudConfirmed: true) {
            XCTAssertEqual($0.state, .downloading); XCTAssertNil($0.fraction)
        }
        tracker.report(resource: 1, fraction: 0, cloudConfirmed: true) { XCTAssertEqual($0.fraction, 0) }
        tracker.report(resource: 1, fraction: 1, cloudConfirmed: true) {
            XCTAssertEqual($0.state, .downloading, "A 100% progress callback is not a successful export.")
        }
        tracker.report(resource: 0, fraction: 0.4) { _ in XCTFail("Late still progress must be ignored") }
        tracker.report(resource: 1, completed: true) {
            XCTAssertEqual($0.state, .ready); XCTAssertTrue($0.cloudConfirmed)
        }
        tracker.report(resource: 1, fraction: 0.5) { _ in XCTFail("Finished resources cannot report again") }
    }

    func testLivePhotoCloudStillThenLocalVideoReturnsToPreparationWithoutLosingCloudFact() {
        let tracker = PackageOriginalProgressTracker(resourceCount: 2)
        tracker.report(resource: 0, cloudConfirmed: true) { _ in }
        tracker.report(resource: 0, fraction: 1, cloudConfirmed: true) { _ in }
        tracker.report(resource: 0, completed: true) { XCTAssertNotEqual($0.state, .ready) }
        tracker.report(resource: 1) {
            XCTAssertEqual($0.state, .preparing); XCTAssertNil($0.fraction); XCTAssertTrue($0.cloudConfirmed)
        }
        tracker.report(resource: 1, fraction: 0.2) {
            XCTAssertEqual($0.state, .preparing); XCTAssertEqual($0.fraction, 0.2)
        }
        tracker.report(resource: 1, completed: true) { XCTAssertEqual($0.state, .ready) }
    }

    func testAcceptedPhotoProgressFinishesBeforeExportReturnsAndLateProgressIsIgnored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try PhotoResourceStream(destination: root.appendingPathComponent("original.mov"), safetyMargin: 0)
        let callbacks = OriginalStreamCallbacks()
        let reports = OriginalTestReports()
        let started = expectation(description: "request registered")
        let progressEntered = expectation(description: "accepted progress callback")
        let progressRelease = DispatchSemaphore(value: 0)
        let returned = expectation(description: "export returned")
        let worker = Task {
            let value = try await stream.export { receive, finish in
                callbacks.register(receive: receive, completion: finish)
                receive(Data("original".utf8)); started.fulfill(); return {}
            }
            reports.markReturned(); returned.fulfill()
            return value
        }
        await fulfillment(of: [started], timeout: 2)
        DispatchQueue.global().async {
            stream.reportProgress(0.5) { _ in
                reports.recordProgress(); progressEntered.fulfill()
                _ = progressRelease.wait(timeout: .now() + 3)
            }
        }
        await fulfillment(of: [progressEntered], timeout: 2)
        callbacks.finish(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(reports.returned, "Export cannot advance to the next resource while accepted progress is still delivering.")
        progressRelease.signal()
        await fulfillment(of: [returned], timeout: 2)
        _ = try await worker.value
        stream.reportProgress(0.8) { _ in reports.recordProgress() }
        XCTAssertEqual(reports.progressEvents, 1)
    }

    func testLocalLivePhotoZIPProgressAggregatesStillAndPairedVideoBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let still = root.appendingPathComponent("original.jpg")
        let video = root.appendingPathComponent("paired.mov")
        try Data(repeating: 0x12, count: 1_048_593).write(to: still)
        try Data(repeating: 0x34, count: 3_145_749).write(to: video)
        let packaging = root.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: packaging)
        var draft = try await service.create(fileURLs: [still, video])
        var photo = try XCTUnwrap(draft.assets.first { $0.kind == .photo })
        photo.pairedFileSource = try XCTUnwrap(draft.assets.first { $0.kind == .video }?.fileSource)
        draft.assets = [photo]
        try PackageLibraryStore(root: packaging).save(draft)
        let reports = OriginalTestReports()
        let result = try await service.run(packageID: draft.id) { reports.append($0) }
        XCTAssertEqual(result.job?.phase, .ready)
        let itemUpdates = reports.updates.filter { $0.assetID == photo.id }
        let zip = itemUpdates.filter { $0.packingFraction != nil }
        XCTAssertFalse(zip.isEmpty)
        XCTAssertTrue(zip.allSatisfy { $0.originalProgress?.state == .ready })
        let fractions = zip.compactMap(\.packingFraction)
        XCTAssertEqual(fractions, fractions.sorted(), "ZIP progress must not reset when advancing to the paired video.")
        XCTAssertEqual(fractions.last, 1)
        let pairedStart = try XCTUnwrap(zip.first { $0.name == "original.jpg" && ($0.packingFraction ?? 0) > 0.24 })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(pairedStart.packingFraction), 0.24)
        let originalEvents = itemUpdates.compactMap(\.originalProgress)
        XCTAssertTrue(originalEvents.contains { $0.state == .preparing })
        XCTAssertTrue(originalEvents.contains { $0.state == .ready })
        XCTAssertFalse(originalEvents.contains { $0.cloudConfirmed }, "Local source hashing must not imply cloud download.")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class OriginalStreamCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var receive: ((Data) -> Void)?
    private var completion: ((Error?) -> Void)?
    func register(receive: @escaping (Data) -> Void, completion: @escaping (Error?) -> Void) {
        lock.lock(); self.receive = receive; self.completion = completion; lock.unlock()
    }
    func send(_ value: Data) { lock.lock(); let action = receive; lock.unlock(); action?(value) }
    func finish(_ error: Error?) { lock.lock(); let action = completion; lock.unlock(); action?(error) }
}

private final class OriginalTestReports: @unchecked Sendable {
    private let lock = NSLock()
    private var cloud = 0, progress = 0
    private var didReturn = false
    private var values: [PackageUpdate] = []
    var cloudEvents: Int { lock.lock(); defer { lock.unlock() }; return cloud }
    var progressEvents: Int { lock.lock(); defer { lock.unlock() }; return progress }
    var returned: Bool { lock.lock(); defer { lock.unlock() }; return didReturn }
    var updates: [PackageUpdate] { lock.lock(); defer { lock.unlock() }; return values }
    func recordCloud() { lock.lock(); cloud += 1; lock.unlock() }
    func recordProgress() { lock.lock(); progress += 1; lock.unlock() }
    func markReturned() { lock.lock(); didReturn = true; lock.unlock() }
    func append(_ value: PackageUpdate) { lock.lock(); values.append(value); lock.unlock() }
}
