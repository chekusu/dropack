import Foundation
import XCTest
@testable import RelayCore

final class LocalizationTests: XCTestCase {
    func testSixteenWebsiteLanguagesResolveFromRegionalSystemVariants() {
        XCTAssertEqual(L10n.supportedLanguages.count, 16)
        XCTAssertEqual(Set(L10n.supportedLanguages.map(\.code)).count, 16)
        XCTAssertEqual(L10n.resolve("en-GB"), "en")
        XCTAssertEqual(L10n.resolve("zh-TW"), "zh-Hant")
        XCTAssertEqual(L10n.resolve("zh-HK"), "zh-Hant")
        XCTAssertEqual(L10n.resolve("zh-CN"), "zh-Hans")
        XCTAssertEqual(L10n.resolve("pt-PT"), "pt-BR")
        XCTAssertEqual(L10n.resolve("ar-SA"), "ar")
        XCTAssertEqual(L10n.resolve("xx-XX"), "en")
    }

    func testUserAlbumNamesAndFilenamesAreNeverTranslatedAsFormatArguments() {
        XCTAssertEqual(L10n.translate("存入：Dropack · %@", arguments: ["发送"], language: "en"), "Save to: Dropack · 发送")
        XCTAssertEqual(L10n.translate("当前素材，%@", arguments: ["照片.jpg"], language: "en"), "Current item, 照片.jpg")
        XCTAssertEqual(L10n.translate("来源中的“发送”已被移动或修改，请重新选择来源。", language: "en"),
            "“发送” was moved or changed. Select the source again.")
    }

    func testRestoredChineseCheckpointMessagesUseCurrentLanguageWithoutMutation() {
        let persisted = "无法准备分享：设备空间不足。当前步骤需要约 3 GB，可用 1 GB。请释放空间后继续。"
        XCTAssertEqual(L10n.translate(persisted, language: "en"),
            "Could not prepare sharing: Not enough space. This step needs about 3 GB; 1 GB is available. Free up space, then resume.")
        XCTAssertTrue(L10n.translate(persisted, language: "ja").hasPrefix("共有を準備できません："))
        XCTAssertEqual(persisted, "无法准备分享：设备空间不足。当前步骤需要约 3 GB，可用 1 GB。请释放空间后继续。")
    }

    func testPercentInFilenameAndProgressIsLiteralNotPrintfCode() {
        XCTAssertEqual(L10n.translate("%@，当前文件 %@%，已保存 %@ 项，共 %@ 项",
            arguments: ["Reading", "45", "3", "10"], language: "en"),
            "Reading, current file 45%, saved 3 of 10 items")
        XCTAssertEqual(L10n.translate("当前素材，%@", arguments: ["100%@.jpg"], language: "en"), "Current item, 100%@.jpg")
    }

    func testUnknownLocaleFallsBackToEnglishAndUnknownUserTextIsPreserved() {
        XCTAssertEqual(L10n.translate("发送", language: "xx"), "Send")
        XCTAssertEqual(L10n.translate("2026-10-14 旅行", language: "en"), "2026-10-14 旅行")
        XCTAssertEqual(L10n.translate("an-unknown-key", language: "en"), "an-unknown-key")
    }

    func testSupportedCatalogsTranslateThePrimaryFlow() {
        for language in L10n.supportedLanguages where language.code != "zh-Hans" {
            let send = L10n.translate("发送", language: language.code)
            XCTAssertFalse(send.isEmpty)
            XCTAssertNotEqual(send, "发送", language.code)
            if language.code != "en" { XCTAssertNotEqual(send, "Send", language.code) }
        }
    }
}
