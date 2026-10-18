import XCTest
import UIKit

/// Current album-based information architecture, exercised with real system
/// pickers and ZIP/Photos operations on the dedicated simulator only.
@MainActor
final class DropackUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Run only on the dedicated Dropack QA simulator.")
#endif
        guard ProcessInfo.processInfo.environment["DROPACK_QA"] == "1" else {
            throw XCTSkip("Set DROPACK_QA=1 on the dedicated QA simulator.")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-dropack.language", "zh-Hans", "-dropack.appearance", "system"]
    }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    /// Establishes permission through the same system prompt as the app. iOS 26
    /// may ignore a legacy simctl Photos grant until this real user response.
    func testAuthorizePhotosForDedicatedQAThroughSystemPrompt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try makeNavigationPackage(at: folder.appendingPathComponent("QA-Authorization.dropack"), count: 1)
        app.launchArguments += ["-dropack-import", fixture.url.path]
        app.launch()
        acceptAlbumSwitchIfNeeded()
        let sync = app.buttons["importPrimaryButton"]
        XCTAssertTrue(sync.waitForExistence(timeout: 30), boundedHierarchy())
        XCTAssertTrue(sync.isEnabled)
        sync.tap()
        allowFullPhotoAccessIfRequested()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: savedThumbnails)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 45), .completed, boundedHierarchy())
        capture("QA-Photos-Authorized")
    }

    func testHomeSendUsesNativeSourceChoiceAndCancelsAtHome() {
        app.launch()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["importPackageButton"].exists)
        capture("01-Home")
        app.buttons["sendPhotosButton"].tap()
        XCTAssertTrue(app.buttons["sendSourcePhotos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sendSourceFiles"].exists)
        XCTAssertFalse(app.buttons["selectMediaButton"].exists)
        capture("02-Native-Source-Choice")
        let cancel = app.buttons["cancelSendSources"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), boundedHierarchy())
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["sendSourcePhotos"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, boundedHierarchy())
        XCTAssertFalse(app.buttons["sendSourceFiles"].exists)
        XCTAssertTrue(app.buttons["sendPhotosButton"].isHittable)
        capture("02b-Source-Choice-Dismissed")
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        navigateBack()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 5))
    }

    func testReceiveOpensFilesWithoutAnIntermediatePage() {
        app.launch()
        XCTAssertTrue(app.buttons["importPackageButton"].waitForExistence(timeout: 15))
        app.buttons["importPackageButton"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), boundedHierarchy())
        XCTAssertFalse(app.buttons["selectZIPButton"].exists)
        XCTAssertFalse(app.buttons["sourceMenuButton"].exists)
        capture("03-Receive-Native-Files")
        cancel.tap()
        XCTAssertTrue(app.buttons["importPackageButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["importPackageButton"].isHittable)
    }

    func testPhotoSelectionGoesToAlbumAndSharingIsInNavigationBar() {
        app.launch()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 15))
        app.buttons["sendPhotosButton"].tap()
        XCTAssertTrue(app.buttons["sendSourcePhotos"].waitForExistence(timeout: 5))
        app.buttons["sendSourcePhotos"].tap()
        allowFullPhotoAccessIfRequested()
        let photos = app.scrollViews["photosView_content_scroll_view"].images.matching(NSPredicate(
            format: "identifier == %@ AND (label CONTAINS[c] %@ OR label CONTAINS %@)",
            "PXGGridLayout-Info", "Photo", "照片"))
        XCTAssertTrue(photos.element(boundBy: 1).waitForExistence(timeout: 15), boundedHierarchy())
        tapObservedThumbnailCenter(photos.element(boundBy: 0))
        tapObservedThumbnailCenter(photos.element(boundBy: 1))
        let add = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done", "添加", "Add"])).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled)
        add.tap()
        let share = app.buttons["libraryShareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 150), boundedHierarchy())
        XCTAssertTrue(app.navigationBars["相册"].exists)
        XCTAssertTrue(app.staticTexts["albumTitle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["packageLibraryAssets"].firstMatch.exists)
        XCTAssertLessThan(share.frame.height, 55)
        XCTAssertLessThan(share.frame.minY, app.frame.height * 0.2)
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
        XCTAssertFalse(app.buttons["shareArchiveButton"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["packageTaskBanner"].firstMatch.exists)
        let title = app.staticTexts["albumTitle"].label
        XCTAssertFalse(title.contains("Dropack-"))
        capture("04-Sent-Album-Detail")
        share.tap()
        closeSystemShareSheet(screenshotName: "05-Native-Share")
        XCTAssertEqual(app.staticTexts["albumTitle"].label, title)
        XCTAssertTrue(app.buttons["libraryShareButton"].isEnabled)
        // Reuse the exact same finalized package after cancellation. A second
        // real remote container must appear and close; button state alone is
        // not proof that native presentation can be invoked again.
        app.buttons["libraryShareButton"].tap()
        closeSystemShareSheet(screenshotName: "05b-Native-Share-Again")
        XCTAssertEqual(app.staticTexts["albumTitle"].label, title)
        app.buttons["albumOptionsButton"].tap()
        XCTAssertTrue(app.buttons["重命名"].waitForExistence(timeout: 5))
        app.buttons["重命名"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1)
        // Use clear text through the keyboard in the actual native alert.
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "海边旅行")
        app.alerts.buttons["保存"].tap()
        let renamed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "海边旅行"), object: app.staticTexts["albumTitle"])
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 150), .completed)
        XCTAssertTrue(app.buttons["libraryShareButton"].waitForExistence(timeout: 150))
        capture("06-Renamed-Album")
    }

    func testReceivedArchiveStaysInAlbumAfterSavingAndReopening() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try makeNavigationPackage(at: folder.appendingPathComponent("接收方重命名-\(UUID().uuidString.prefix(6)).dropack"), count: 2)
        app.launchArguments += ["-dropack-import", archive.url.path]
        app.launch()
        acceptAlbumSwitchIfNeeded()
        XCTAssertTrue(app.buttons["importPrimaryButton"].waitForExistence(timeout: 30), boundedHierarchy())
        XCTAssertTrue(app.navigationBars["相册"].exists)
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receivedAlbumAssets"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts["albumTitle"].label, "海边旅行")
        XCTAssertFalse(app.staticTexts["albumTitle"].label.contains("接收方重命名"))
        capture("07-Received-Album-Preview")
        let sync = app.buttons["importPrimaryButton"]
        if sync.isEnabled { sync.tap(); allowPhotoWriteIfRequested() }
        let photosSaved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: savedThumbnails)
        XCTAssertEqual(XCTWaiter.wait(for: [photosSaved], timeout: 60), .completed, boundedHierarchy())
        let taskFinished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["nativeImportPauseResume"])
        XCTAssertEqual(XCTWaiter.wait(for: [taskFinished], timeout: 10), .completed, boundedHierarchy())
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(sync.label, "同步到相册")
        XCTAssertFalse(app.staticTexts["importSavedCount"].exists)
        XCTAssertFalse(app.staticTexts["previouslySavedCount"].exists)
        XCTAssertEqual(savedThumbnails.count, 2)
        XCTAssertTrue(app.navigationBars["相册"].exists)
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
        capture("08-Received-Album-Complete")
        app.terminate()
        app.launch()
        acceptAlbumSwitchIfNeeded()
        XCTAssertTrue(app.buttons["importPrimaryButton"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["importPrimaryButton"].isEnabled)
        XCTAssertEqual(savedThumbnails.count, 2)
        XCTAssertFalse(app.staticTexts["importStatus"].exists)
        XCTAssertFalse(app.staticTexts["previouslySavedCount"].exists)
        capture("09-Reopened-Without-Duplicates")
    }

    private var savedThumbnails: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND value == %@", "previewReceivedAsset-", "已存入相册"))
    }

    func testReceivedAlbumHasFixedSyncAndCanForwardBeforeSaving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try makeNavigationPackage(at: folder.appendingPathComponent("未同步转发.dropack"), count: 30)
        app.launchArguments += ["-dropack-import", archive.url.path]
        app.launch()
        acceptAlbumSwitchIfNeeded()
        let sync = app.buttons["importPrimaryButton"]
        XCTAssertTrue(sync.waitForExistence(timeout: 30), boundedHierarchy())
        XCTAssertTrue(sync.isEnabled)
        XCTAssertEqual(sync.label, "同步到相册")
        XCTAssertGreaterThan(sync.frame.minY, app.frame.height * 0.75)
        XCTAssertGreaterThan(sync.frame.width, min(app.frame.width * 0.8, 500))
        XCTAssertFalse(app.staticTexts["importSavedCount"].exists)
        XCTAssertFalse(app.staticTexts["importStatus"].exists)
        XCTAssertTrue(app.staticTexts["albumSummary"].label.contains("Alex’s iPhone"))
        let initialY = sync.frame.minY
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(sync.frame.minY, initialY, accuracy: 2)
        XCTAssertTrue(sync.isHittable)
        let share = app.buttons["receivedShareButton"]
        XCTAssertTrue(share.isEnabled)
        XCTAssertLessThan(share.frame.minY, app.frame.height * 0.2)
        share.tap()
        closeSystemShareSheet(screenshotName: "Received-Forward-Before-Sync", returningTo: "receivedShareButton")
        XCTAssertEqual(savedThumbnails.count, 0)
        XCTAssertTrue(sync.isEnabled)
        app.buttons["receivedAlbumOptionsButton"].tap()
        app.buttons["receivedAlbumInfoButton"].tap()
        XCTAssertTrue(app.staticTexts["importSavedCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["importSavedCount"].label, "0 / 30 项")
        app.buttons["albumInfoDoneButton"].tap()
        XCTAssertTrue(sync.isHittable)
    }

    func testSharedAlbumLibrarySegmentsAndDeepLinkPreserveReceivedContext() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try makeNavigationPackage(at: folder.appendingPathComponent("随意文件名.dropack"), count: 2)
        app.launchArguments += ["-dropack-import", fixture.url.path]
        app.launch()
        acceptAlbumSwitchIfNeeded()
        XCTAssertTrue(app.staticTexts["albumTitle"].waitForExistence(timeout: 30), boundedHierarchy())
        XCTAssertEqual(app.staticTexts["albumTitle"].label, "海边旅行")
        XCTAssertTrue(app.navigationBars["相册"].exists)
        let savedBefore = savedThumbnails.count
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-dropack.language", "zh-Hans", "-dropack.appearance", "system",
            "-dropack-url", "dropack://albums/received/\(fixture.albumID.uuidString.lowercased())"]
        app.launch()
        XCTAssertTrue(app.staticTexts["albumTitle"].waitForExistence(timeout: 30), boundedHierarchy())
        XCTAssertTrue(app.navigationBars["相册"].exists)
        XCTAssertEqual(app.staticTexts["albumTitle"].label, "海边旅行")
        XCTAssertEqual(savedThumbnails.count, savedBefore, "Opening a deep link must not start saving.")
        XCTAssertTrue(app.buttons["importPrimaryButton"].isEnabled)
        XCTAssertFalse(app.buttons["nativeImportPauseResume"].exists)
        navigateBack()
        XCTAssertTrue(app.navigationBars["分享相册"].waitForExistence(timeout: 5), boundedHierarchy())
        let segments = app.segmentedControls["albumLibrarySegments"]
        XCTAssertTrue(segments.waitForExistence(timeout: 5), boundedHierarchy())
        XCTAssertTrue(segments.buttons["收到的"].isSelected)
        let row = app.buttons["receivedAlbumRow-\(fixture.albumID)"]
        XCTAssertTrue(row.exists)
        segments.buttons["我分享的"].tap()
        XCTAssertTrue(segments.buttons["我分享的"].isSelected)
        XCTAssertFalse(row.exists)
        capture("11-Library-Sent-Segment")
        segments.buttons["收到的"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture("12-Library-Received-Segment")
        row.tap()
        XCTAssertTrue(app.navigationBars["相册"].waitForExistence(timeout: 5))
        navigateBack()
        XCTAssertTrue(segments.waitForExistence(timeout: 5))
        XCTAssertTrue(segments.buttons["收到的"].isSelected)
        XCTAssertTrue(row.exists)
    }

    func testPlainZIPImportFinishesAtHomeWithoutCreatingReceivedAlbum() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let filename = "一次性相机素材-\(UUID().uuidString.prefix(8)).zip"
        let fixture = try makeNavigationPackage(at: folder.appendingPathComponent(filename), count: 2, includeManifest: false)
        app.launchArguments += ["-dropack-import", fixture.url.path]
        app.launch()
        acceptAlbumSwitchIfNeeded()
        let detail = app.descendants(matching: .any)["oneTimeImportDetail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 30), boundedHierarchy())
        XCTAssertTrue(app.navigationBars["导入"].exists)
        XCTAssertEqual(app.staticTexts["albumTitle"].label, filename)
        XCTAssertFalse(app.buttons["receivedShareButton"].exists)
        XCTAssertFalse(app.buttons["允许完整访问以关联相册"].exists)
        capture("13-Plain-ZIP-One-Time-Import")
        let save = app.buttons["importPrimaryButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.label.contains("保存到相册"))
        save.tap()
        allowPhotoWriteIfRequested()
        let finish = app.buttons["finishImportButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 60), boundedHierarchy())
        XCTAssertTrue(finish.isEnabled)
        XCTAssertEqual(savedThumbnails.count, 2)
        capture("14-One-Time-Import-Complete")
        finish.tap()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["importPackageButton"].exists)
        XCTAssertFalse(detail.exists)
        app.buttons["packageLibraryButton"].tap()
        let segments = app.segmentedControls["albumLibrarySegments"]
        XCTAssertTrue(segments.waitForExistence(timeout: 5))
        segments.buttons["收到的"].tap()
        XCTAssertFalse(app.staticTexts[filename].exists)
        XCTAssertFalse(app.buttons["receivedAlbumRow-\(fixture.albumID)"].exists)
        capture("15-Import-Not-In-Received-Library")
    }

    func testInvalidIncomingFileKeepsRetryAndDoesNotCreateAlbum() {
        app.launchArguments += ["-dropack-import", "/tmp/Missing-Share-Album.dropack"]
        app.launch()
        acceptAlbumSwitchIfNeeded()
        let retry = app.buttons["openIncomingPackageButton"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["读取文件"].exists)
        XCTAssertTrue(app.staticTexts["Missing-Share-Album.dropack"].exists)
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
        capture("10-Incoming-Error-Retry")
    }

    private func acceptAlbumSwitchIfNeeded() {
        let open = app.alerts.buttons["打开所选文件"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private func allowPhotoWriteIfRequested() {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [system, app].compactMap({ $0 }) {
            if host.alerts.firstMatch.waitForExistence(timeout: 3) {
                let labels = ["允许完全访问", "允许访问所有照片", "允许访问全部照片", "Allow Full Access", "Allow Access to All Photos", "允许添加照片", "Allow Photos to Be Added", "允许", "Allow"]
                let button = host.alerts.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                if button.exists { button.tap() }
            }
        }
    }

    private struct NavigationFixture {
        let url: URL
        let albumID: UUID
    }

    /// A real portable v1 manifest is required to make this a shared album.
    /// Merely putting a .dropack suffix on an ordinary ZIP is intentionally not enough.
    private func makeNavigationPackage(at url: URL, count: Int, includeManifest: Bool = true) throws -> NavigationFixture {
        let albumID = UUID()
        var files: [(String, Data)] = []
        var items: [[String: Any]] = []
        let date = Date().timeIntervalSinceReferenceDate
        for index in 0..<count {
            let id = UUID().uuidString
            let path = "media/\(id)/original.jpg"
            let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32))
                .jpegData(withCompressionQuality: 0.8) { context in
                    UIColor(hue: CGFloat(index + 1) / CGFloat(count + 2), saturation: 0.65, brightness: 0.75, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
                    UIColor.white.setFill()
                    context.fill(CGRect(x: CGFloat(index + 2), y: CGFloat(index + 2), width: 5, height: 7))
                    // Different fixture albums must have different image bytes,
                    // otherwise persistent dedup history can pre-complete a test.
                    for (position, byte) in albumID.uuidString.utf8.enumerated() {
                        UIColor(white: CGFloat(byte % 16) / 15, alpha: 1).setFill()
                        context.fill(CGRect(x: CGFloat((position % 9) * 5), y: CGFloat((position / 9) * 7), width: 4, height: 6))
                    }
                }
            files.append((path, image))
            items.append(["id": id, "photoPath": path, "creationDate": date - Double(count - index) * 60,
                          "isLivePhoto": false])
        }
        if includeManifest {
            let manifest: [String: Any] = ["version": 1, "items": items,
                "album": ["id": albumID.uuidString, "snapshotID": UUID().uuidString, "revision": 1,
                          "title": "海边旅行", "senderName": "Alex’s iPhone", "createdAt": date, "updatedAt": date]]
            files.append(("dropack-manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])))
        }
        try makeStoredZIP(files, at: url)
        return NavigationFixture(url: url, albumID: albumID)
    }

    private func makeStoredZIP(_ files: [(String, Data)], at url: URL) throws {
        func u16(_ value: UInt16) -> Data {
            var little = value.littleEndian
            return withUnsafeBytes(of: &little) { Data($0) }
        }
        func u32(_ value: UInt32) -> Data {
            var little = value.littleEndian
            return withUnsafeBytes(of: &little) { Data($0) }
        }
        func crc32(_ bytes: Data) -> UInt32 {
            var checksum: UInt32 = .max
            for byte in bytes {
                checksum ^= UInt32(byte)
                for _ in 0..<8 { checksum = (checksum >> 1) ^ (checksum & 1 == 1 ? 0xedb88320 : 0) }
            }
            return checksum ^ .max
        }
        var archive = Data()
        var directory = Data()
        for (path, bytes) in files {
            let name = Data(path.utf8)
            let checksum = crc32(bytes)
            let offset = UInt32(archive.count)
            archive += u32(0x04034b50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            archive += u32(checksum) + u32(UInt32(bytes.count)) + u32(UInt32(bytes.count))
            archive += u16(UInt16(name.count)) + u16(0) + name + bytes
            directory += u32(0x02014b50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            directory += u32(checksum) + u32(UInt32(bytes.count)) + u32(UInt32(bytes.count))
            directory += u16(UInt16(name.count)) + u16(0) + u16(0) + u16(0) + u16(0)
            directory += u32(0) + u32(offset) + name
        }
        let directoryOffset = UInt32(archive.count)
        archive += directory
        archive += u32(0x06054b50) + u16(0) + u16(0) + u16(UInt16(files.count)) + u16(UInt16(files.count))
        archive += u32(UInt32(directory.count)) + u32(directoryOffset) + u16(0)
        try archive.write(to: url)
    }

    private func allowFullPhotoAccessIfRequested() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        let appAlert = app.alerts.firstMatch
        // iOS 26 can require a real authorization response even after simctl's
        // Photos grant. Limit the action to explicit full-access buttons in QA.
        if systemAlert.waitForExistence(timeout: 5) {
            tapFullPhotoAccess(in: systemAlert)
        } else if appAlert.exists {
            tapFullPhotoAccess(in: appAlert)
        }
    }

    private func tapFullPhotoAccess(in alert: XCUIElement) {
        let labels = ["允许完全访问", "允许访问所有照片", "允许访问全部照片", "Allow Full Access", "Allow Access to All Photos"]
        let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5),
                      "Unexpected permission alert; do not choose a different permission implicitly. \(alert.debugDescription)")
        allow.tap()
    }

    private func closeSystemShareSheet(screenshotName: String, returningTo identifier: String = "libraryShareButton") {
        let container = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        XCTAssertTrue(container.waitForExistence(timeout: 60),
                      "Expected the actual system sharing container. \(boundedHierarchy())")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            container.exists && !container.frame.isEmpty && self.app.frame.intersects(container.frame)
        }, object: container)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed,
                       "The system sharing container must be on screen before dismissal.")
        capture(screenshotName)
        let close = app.buttons["header.closeButton"]
        if close.exists {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
            let canClose = XCTWaiter.wait(for: [ready], timeout: 10) == .completed
            if !canClose { captureDiagnostics("Failure-Share-Close-Not-Hittable") }
            XCTAssertTrue(canClose, "Wait for the observed close button to be actionable.")
            close.tap()
        } else {
            // On iOS 26.2 native sharing is a popover without a close button.
            // Derive a point from the observed dismissal region, outside the
            // observed popover; do not tap the underlying album blindly.
            let dismissal = app.otherElements["PopoverDismissRegion"].firstMatch
            let popover = app.popovers.firstMatch
            XCTAssertTrue(dismissal.waitForExistence(timeout: 10), boundedHierarchy())
            XCTAssertTrue(popover.exists, "A missing close button requires an actual popover dismissal region.")
            let region = dismissal.frame.intersection(app.frame)
            let content = popover.frame.union(container.frame)
            XCTAssertFalse(region.isNull || region.isEmpty)
            XCTAssertFalse(content.isEmpty)
            let candidates = [
                CGPoint(x: region.midX, y: (region.minY + content.minY) / 2),
                CGPoint(x: region.midX, y: (content.maxY + region.maxY) / 2),
                CGPoint(x: (region.minX + content.minX) / 2, y: region.midY),
                CGPoint(x: (content.maxX + region.maxX) / 2, y: region.midY)
            ]
            guard let point = candidates.first(where: {
                region.insetBy(dx: 24, dy: 64).contains($0) &&
                !content.insetBy(dx: -12, dy: -12).contains($0)
            }) else {
                captureDiagnostics("Failure-Share-No-Observed-Dismissal-Point")
                XCTFail("No safe observed point outside the share popover: region=\(region), content=\(content)")
                return
            }
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: container)
        let didDismiss = XCTWaiter.wait(for: [dismissed], timeout: 10) == .completed
        if !didDismiss { captureDiagnostics("Failure-Share-Did-Not-Dismiss") }
        XCTAssertTrue(didDismiss, "The system share sheet must actually disappear before interacting with the underlying package.")
        let share = app.buttons[identifier]
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: share)
        let canShareAgain = XCTWaiter.wait(for: [returned], timeout: 10) == .completed
        if !canShareAgain { captureDiagnostics("Failure-Share-Underlying-Button-Blocked") }
        XCTAssertTrue(canShareAgain, "Cancelling sharing must return to an accessible, reusable finalized package.")
    }

    private func tapObservedThumbnailCenter(_ image: XCUIElement) {
        let frame = image.frame
        let viewport = app.scrollViews["photosView_content_scroll_view"].frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(app.frame.contains(frame) && viewport.contains(frame),
                      "Only an observed, fully visible photo thumbnail may receive a coordinate tap: \(frame)")
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: frame.midX - app.frame.minX,
                                   dy: frame.midY - app.frame.minY)).tap()
    }

    private func boundedHierarchy() -> String {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        return "APP:\n\(String(app.debugDescription.prefix(18000)))\nSYSTEM:\n\(String(system.debugDescription.prefix(10000)))"
    }

    private func captureDiagnostics(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: boundedHierarchy())
        hierarchy.name = name + "-Hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func navigateBack() {
        let namedBack = app.navigationBars.buttons["Dropack"]
        if namedBack.exists { namedBack.tap() }
        else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
