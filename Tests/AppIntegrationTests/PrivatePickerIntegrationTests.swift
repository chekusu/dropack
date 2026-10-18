import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Dropack

@MainActor
final class PrivatePickerIntegrationTests: XCTestCase {
    private var temporary: URL!
    override func setUp() async throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: temporary) }

    func testPrivatePickerGrantCapturesDurableSourcesAndResumesAfterProviderDisappears() async throws {
        let source = temporary.appendingPathComponent("picker-temporary.jpg")
        let bytes = Data(repeating: 7, count: 2 * 1024 * 1024 + 17)
        try bytes.write(to: source)
        let selection = PhotoPickerSelection(items: [.init(assetIdentifier: "outside-limited-library", provider: provider(url: source))])
        let root = temporary.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: root)
        let draft = try await service.create(selection: selection)
        XCTAssertEqual(draft.totalCount, 1)
        XCTAssertEqual(draft.assets[0].pickerResourcePending, true)
        XCTAssertNil(draft.linkedPhotosAlbumIdentifier)
        try await service.preparePickerSources(packageID: draft.id, selection: selection) { _ in }
        let store = PackageLibraryStore(root: root)
        let captured = try XCTUnwrap(store.load(id: draft.id))
        XCTAssertEqual(captured.assets[0].pickerResourcePending, false)
        let file = try PackageFileAccess.resolve(XCTUnwrap(captured.assets[0].fileSource)).file
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: source)
        let restarted = PhotoPackageService(root: root)
        let ready = try await restarted.run(packageID: draft.id) { _ in }
        XCTAssertEqual(ready.job?.phase, .ready)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let shared = try await restarted.shareURL(packageID: draft.id, format: .dropack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testRestartAndReorderedReselectionReadsOnlyMissingResourceInOriginalAlbum() async throws {
        let first = temporary.appendingPathComponent("first.jpg")
        let second = temporary.appendingPathComponent("second.jpg")
        try Data("first resource".utf8).write(to: first)
        try Data("second resource".utf8).write(to: second)
        let broken = NSItemProvider()
        broken.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            completion(nil, false, NSError(domain: "PrivatePickerTest", code: 1)); return nil
        }
        let selection = PhotoPickerSelection(items: [
            .init(assetIdentifier: "private-first", provider: provider(url: first)),
            .init(assetIdentifier: "private-second", provider: broken)])
        let root = temporary.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: root)
        let draft = try await service.create(selection: selection)
        do { try await service.preparePickerSources(packageID: draft.id, selection: selection) { _ in }; XCTFail("Failed picker item must not be skipped") }
        catch { XCTAssertNotNil(error) }
        let store = PackageLibraryStore(root: root)
        let failed = try XCTUnwrap(store.load(id: draft.id))
        XCTAssertEqual(failed.assets[0].pickerResourcePending, false)
        XCTAssertEqual(failed.assets[1].pickerResourcePending, true)
        try FileManager.default.removeItem(at: first)
        let retry = PhotoPickerSelection(items: [.init(assetIdentifier: "private-second", provider: provider(url: second)), selection.items[0]])
        // Simulate a terminated process: only persisted local IDs survive.
        let restarted = PhotoPackageService(root: root)
        let rebound = try await restarted.reselect(packageID: draft.id, selection: retry)
        XCTAssertEqual(rebound.id, draft.id)
        XCTAssertEqual(rebound.stableAlbumID, draft.stableAlbumID)
        XCTAssertEqual(rebound.assets.map(\.id), draft.assets.map(\.id))
        let capturedURL = try PackageFileAccess.resolve(XCTUnwrap(failed.assets[0].fileSource)).file
        let capturedBytes = try Data(contentsOf: capturedURL)
        let capturedDate = try capturedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await restarted.preparePickerSources(packageID: draft.id, selection: retry) { _ in }
        XCTAssertEqual(try Data(contentsOf: capturedURL), capturedBytes)
        XCTAssertEqual(try capturedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, capturedDate)
        let ready = try await restarted.run(packageID: draft.id) { _ in }
        XCTAssertEqual(ready.job?.phase, .ready)
        XCTAssertEqual(ready.job?.totalCount, 2)
    }

    func testReselectionRejectsWrongOrAmbiguousIDsWithoutChangingDraft() async throws {
        let source = temporary.appendingPathComponent("original.jpg")
        try Data("original private resource".utf8).write(to: source)
        let root = temporary.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: root)
        let draft = try await service.create(selection: PhotoPickerSelection(items: [
            .init(assetIdentifier: "original-local-id", provider: provider(url: source))]))
        let store = PackageLibraryStore(root: root)
        let before = try Data(contentsOf: store.checkpointURL(id: draft.id))
        let restarted = PhotoPackageService(root: root)
        for selection in [
            PhotoPickerSelection(items: [.init(assetIdentifier: "wrong-local-id", provider: provider(url: source))]),
            PhotoPickerSelection(items: [.init(assetIdentifier: "original-local-id", provider: provider(url: source)),
                .init(assetIdentifier: "original-local-id", provider: provider(url: source))])
        ] {
            do { _ = try await restarted.reselect(packageID: draft.id, selection: selection); XCTFail("Unsafe rebind must fail") }
            catch { guard case PhotoPackageError.pickerReselectionMismatch = error else { return XCTFail("Unexpected error: \(error)") } }
        }
        XCTAssertEqual(try Data(contentsOf: store.checkpointURL(id: draft.id)), before)
        XCTAssertEqual(try store.allEntries().count, 1)
    }

    func testFreshNilIdentifierSelectionCannotGuessInterruptedResource() async throws {
        let source = temporary.appendingPathComponent("no-id.jpg")
        try Data("private resource with no local ID".utf8).write(to: source)
        let root = temporary.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: root)
        let draft = try await service.create(selection: PhotoPickerSelection(items: [
            .init(assetIdentifier: nil, provider: provider(url: source))]))
        let store = PackageLibraryStore(root: root)
        let before = try Data(contentsOf: store.checkpointURL(id: draft.id))
        let restarted = PhotoPackageService(root: root)
        let newSelection = PhotoPickerSelection(items: [.init(assetIdentifier: nil, provider: provider(url: source))])
        do { _ = try await restarted.reselect(packageID: draft.id, selection: newSelection); XCTFail("Same filename/order cannot identify an asset") }
        catch { guard case PhotoPackageError.pickerReselectionUnavailable = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: store.checkpointURL(id: draft.id)), before)
        XCTAssertEqual(try store.allEntries().count, 1)
    }

    func testCancelledBoundedCopyKeepsSourceAndRemovesOnlyPartialDestination() throws {
        let source = temporary.appendingPathComponent("large.jpg")
        let target = temporary.appendingPathComponent("owned.jpg")
        let original = Data(repeating: 9, count: 3 * 1024 * 1024)
        try original.write(to: source)
        var cancellationChecks = 0
        XCTAssertThrowsError(try PickerResourceExporter.copy(source, to: target, isCancelled: {
            cancellationChecks += 1; return cancellationChecks > 1
        }, progress: { _ in })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathExtension("partial").path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPendingPrivateSourcesCannotBePackedAfterGrantWasLost() async throws {
        let source = temporary.appendingPathComponent("source.jpg")
        try Data("pending".utf8).write(to: source)
        let root = temporary.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: root)
        let draft = try await service.create(selection: PhotoPickerSelection(items: [.init(assetIdentifier: nil, provider: provider(url: source))]))
        let restarted = PhotoPackageService(root: root)
        do { _ = try await restarted.run(packageID: draft.id) { _ in }; XCTFail("Missing picker grant must not silently produce partial album") }
        catch {
            guard case PhotoPackageError.pickerReselection = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try PackageLibraryStore(root: root).load(id: draft.id)?.completedCount, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data("pending".utf8))
    }

    private func provider(url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            // Intentionally synchronous: the implementation must tolerate a
            // callback completing before loadFileRepresentation returns Progress.
            completion(url, false, nil)
            let progress = Progress(totalUnitCount: 1); progress.completedUnitCount = 1
            return progress
        }
        return provider
    }
}
