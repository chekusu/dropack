import CryptoKit
import Foundation
import XCTest
import ZIPFoundation
@testable import Dropack

final class PackageCancellationIntegrationTests: XCTestCase {
    func testPhotoResourceCancellationClosesFileWithoutCompletionAndIgnoresLateWrites() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let stream = try PhotoResourceStream(destination: destination, safetyMargin: 0)
        let callback = StreamCallbacks()
        let reports = ByteReports()
        let started = expectation(description: "Streaming started")
        let finished = expectation(description: "Cancelled export returned")
        let task = Task {
            do {
                _ = try await stream.export(readProgress: { reports.append($0) }) { receive, completion in
                    callback.register(receive: receive, completion: completion)
                    receive(Data("partial original".utf8))
                    started.fulfill()
                    return { callback.recordCancellation() } // No completion is delivered.
                }
                XCTFail("Must cancel")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(callback.cancellations, 1)
        XCTAssertEqual(reports.values.last, UInt64(Data("partial original".utf8).count))
        let reportCount = reports.values.count
        // Model enclosing package cleanup and a replacement worker reusing the
        // same path. Late callbacks must neither recreate nor append to it.
        try FileManager.default.removeItem(at: destination)
        let replacement = Data("new worker owns this file".utf8)
        try replacement.write(to: destination)
        callback.send(Data("late old data".utf8))
        callback.finish(nil)
        callback.finish(CancellationError())
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(reports.values.count, reportCount, "Retired callback must not report stale progress")
    }

    func testSynchronousPhotoResourceCompletionPreservesByteCountAndHash() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let stream = try PhotoResourceStream(destination: destination, safetyMargin: 0)
        let bytes = Data(repeating: 31, count: 2 * 1024 * 1024 + 19)
        let reports = ByteReports()
        let result = try await stream.export(readProgress: { reports.append($0) }) { receive, completion in
            receive(bytes.prefix(1024 * 1024))
            receive(bytes.dropFirst(1024 * 1024))
            completion(nil)
            completion(nil)
            receive(Data("late".utf8))
            return {}
        }
        XCTAssertEqual(result.byteCount, UInt64(bytes.count))
        XCTAssertEqual(reports.values.first, 1_048_576)
        XCTAssertEqual(reports.values.last, UInt64(bytes.count), "Final exact bytes must flush without an iCloud progress callback")
        XCTAssertEqual(reports.values, reports.values.sorted())
        XCTAssertEqual(result.hash, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testCancellationDuringRealZIPAppendRollsBackAndCanResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        // Only filesystem/ZIP behavior is under test; never insert this fixture
        // into Photos. Multiple chunks make cancellation during append certain.
        let bytes = Data(repeating: 0x47, count: 8 * 1024 * 1024 + 17)
        try bytes.write(to: source)
        let packaging = root.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: packaging)
        let draft = try await service.create(fileURLs: [source])
        let store = PackageLibraryStore(root: packaging)
        let archiveURL = try store.directory(id: draft.id).appendingPathComponent(draft.archiveFilename)
        let before = try Data(contentsOf: archiveURL)
        let cancelled = expectation(description: "Cancelled inside ZIP data provider")
        let worker = Task {
            try await service.run(packageID: draft.id) { update in
                if update.stage == "正在打包", update.fraction > 0, update.fraction < 1 {
                    withUnsafeCurrentTask { task in
                        XCTAssertNotNil(task)
                        task?.cancel()
                    }
                    cancelled.fulfill()
                }
            }
        }
        do { _ = try await worker.value; XCTFail("ZIP append must stop at next chunk") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 2)
        let paused = try XCTUnwrap(store.load(id: draft.id))
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertNil(paused.transaction)
        XCTAssertEqual(paused.completedCount, 0)
        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let resumed = try await service.run(packageID: draft.id) { _ in }
        XCTAssertEqual(resumed.job?.phase, .ready)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let media = try XCTUnwrap(Array(archive).first { $0.path.hasPrefix("media/") })
        var extracted = Data()
        let checksum = try archive.extract(media) { extracted.append($0) }
        XCTAssertEqual(checksum, media.checksum)
        XCTAssertEqual(extracted, bytes)
    }

    func testDuplicateLocalFilenamesReportDistinctAssetIDsThroughHashZIPAndFinalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["camera-a", "camera-b"].map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in sources {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x71, count: 1_048_593).write(to: folder.appendingPathComponent("IMG_0001.mov"))
        }
        let service = PhotoPackageService(root: root.appendingPathComponent("Packages"))
        let draft = try await service.create(fileURLs: sources.map { $0.appendingPathComponent("IMG_0001.mov") })
        XCTAssertEqual(Set(draft.assets.compactMap(\.title)), ["IMG_0001.mov"])
        let expectedIDs = Set(draft.assets.map(\.id))
        XCTAssertEqual(expectedIDs.count, 2)
        let reports = PackageUpdateReports()
        let result = try await service.run(packageID: draft.id) { reports.append($0) }
        XCTAssertEqual(result.job?.phase, .ready)
        let updates = reports.values
        XCTAssertEqual(Set(updates.filter { $0.stage == "核对文件" }.compactMap(\.assetID)), expectedIDs)
        XCTAssertEqual(Set(updates.filter { $0.stage == "正在打包" && $0.name == "IMG_0001.mov" }.compactMap(\.assetID)), expectedIDs)
        let checkpoints = updates.compactMap { $0.job }.filter { $0.completedCount > 0 }
        XCTAssertTrue(checkpoints.contains { $0.completedCount == 1 })
        XCTAssertEqual(Set(try XCTUnwrap(checkpoints.last).assets.filter(\.isCompleted).map(\.id)), expectedIDs)
        XCTAssertTrue(updates.filter { $0.stage == "生成照片包清单" || $0.stage == "核对照片包" || $0.name == "照片包清单" }
            .allSatisfy { $0.assetID == nil }, "Finalization must not be attributed to the last photo.")
    }

    func testPickerCancellationDoesNotDependOnProviderCompletion() async {
        let request = PickerProviderRequest<URL>()
        let started = expectation(description: "Picker request started")
        let returned = expectation(description: "Picker request returned")
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                _ = try await request.perform(start: { started.fulfill(); return progress }, progress: { _ in })
                XCTFail("Must cancel")
            } catch { XCTAssertTrue(error is CancellationError) }
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertTrue(progress.isCancelled)
        request.receive(error: nil) { XCTFail("Cancelled picker callback cannot copy"); return URL(fileURLWithPath: "/unused") }
    }
}

private final class StreamCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var receive: ((Data) -> Void)?
    private var completion: ((Error?) -> Void)?
    private var cancellationCount = 0
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return cancellationCount }
    func register(receive: @escaping (Data) -> Void, completion: @escaping (Error?) -> Void) {
        lock.lock(); self.receive = receive; self.completion = completion; lock.unlock()
    }
    func recordCancellation() { lock.lock(); cancellationCount += 1; lock.unlock() }
    func send(_ data: Data) { lock.lock(); let callback = receive; lock.unlock(); callback?(data) }
    func finish(_ error: Error?) { lock.lock(); let callback = completion; lock.unlock(); callback?(error) }
}

private final class ByteReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [UInt64] = []
    var values: [UInt64] { lock.lock(); defer { lock.unlock() }; return reports }
    func append(_ bytes: UInt64) { lock.lock(); reports.append(bytes); lock.unlock() }
}

private final class PackageUpdateReports: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [PackageUpdate] = []
    var values: [PackageUpdate] { lock.lock(); defer { lock.unlock() }; return updates }
    func append(_ update: PackageUpdate) { lock.lock(); updates.append(update); lock.unlock() }
}
