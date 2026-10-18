import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Use the dedicated Dropack QA simulator.")
#endif
        guard ProcessInfo.processInfo.environment["DROPACK_QA"] == "1" else {
            throw XCTSkip("DROPACK_QA is required.")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-dropack.language", "zh-Hans", "-dropack.appearance", "system"]
    }

    override func tearDownWithError() throws { app?.terminate(); app = nil }

    func testSettingsLanguageThemeAndVersionStayOnTheirOwnRoute() {
        // Do not pin preferences in NSArgumentDomain while testing live changes.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 20))
        app.buttons["settingsButton"].tap()
        if !app.navigationBars["设置"].exists {
            app.buttons["languagePicker"].tap()
            let chinese = app.descendants(matching: .any)["language-zh-Hans"].firstMatch
            XCTAssertTrue(chinese.waitForExistence(timeout: 5))
            chinese.tap()
            if !app.navigationBars["设置"].waitForExistence(timeout: 1) {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
        }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["installedAppVersion"].firstMatch.exists)
        app.buttons["checkForUpdatesButton"].tap()
        XCTAssertTrue(app.staticTexts["updateCheckResult"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["updateCheckResult"].label.contains("开发"))

        app.buttons["languagePicker"].tap()
        let english = app.descendants(matching: .any)["language-en"].firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        // A native picker remains in its navigation hierarchy. Changing language
        // must not replace ContentView or send the user to the home screen.
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
        if !app.navigationBars["Settings"].waitForExistence(timeout: 1) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["appearancePicker"].tap()
        let dark = app.descendants(matching: .any)["theme-dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 1) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("Settings-English-Dark")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sendPhotosButton"].label.contains("Send"))
        capture("Home-English-Dark")
        app.buttons["sendPhotosButton"].tap()
        XCTAssertTrue(app.buttons["sendSourcePhotos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sendSourcePhotos"].label.contains("Photos"))
        app.buttons["cancelSendSources"].tap()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 5))
    }

    func testLiveRTLToSystemLanguageKeepsSettingsReadableAfterThemeChange() {
        // Keep preferences writable: an NSArgumentDomain language override would
        // mask real user changes and never exercise the retained native Form.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 20))
        app.buttons["settingsButton"].tap()

        selectLiveLanguage("system", settingsTitle: "设置")
        XCTAssertTrue(app.buttons["appearancePicker"].label.contains("主题"))
        selectLiveLanguage("ar", settingsTitle: "الإعدادات")
        XCTAssertTrue(app.buttons["appearancePicker"].label.contains("السمة"))
        capture("Settings-Live-Arabic")

        selectLiveLanguage("system", settingsTitle: "设置")
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
        XCTAssertTrue(app.buttons["appearancePicker"].label.contains("主题"))
        capture("Settings-Live-System-After-Arabic")

        app.buttons["appearancePicker"].tap()
        let dark = app.descendants(matching: .any)["theme-dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        if !app.navigationBars["设置"].waitForExistence(timeout: 1) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture("Settings-Live-System-Dark-After-Arabic")
        XCTAssertEqual(app.buttons["appearancePicker"].value as? String, "深色",
                       app.buttons["appearancePicker"].debugDescription)
        // Accessibility geometry catches a retained RTL row layout. The
        // screenshot also covers mirrored glyphs, which geometry cannot detect.
        let appearanceLabel = app.staticTexts["主题"].firstMatch
        XCTAssertTrue(appearanceLabel.waitForExistence(timeout: 5))
        XCTAssertLessThan(appearanceLabel.frame.midX, app.frame.midX)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sendPhotosButton"].label.contains("发送"))
        capture("Home-Live-System-Dark-After-Arabic")
    }

    private func selectLiveLanguage(_ code: String, settingsTitle: String) {
        XCTAssertTrue(app.buttons["languagePicker"].waitForExistence(timeout: 5))
        app.buttons["languagePicker"].tap()
        let option = app.descendants(matching: .any)["language-" + code].firstMatch
        // Arabic is near the end of the native list on an iPhone.
        for _ in 0..<6 {
            if option.exists && option.isHittable { break }
            if code == "system" { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertTrue(option.isHittable)
        option.tap()
        if !app.navigationBars[settingsTitle].waitForExistence(timeout: 1) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars[settingsTitle].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sendPhotosButton"].exists)
    }

    func testAllWebsiteLanguagesHaveLocalizedHomeAndSettings() {
        let languages: [(String, String, String)] = [
            ("en", "Send", "Settings"), ("zh-Hans", "发送", "设置"),
            ("zh-Hant", "發送", "設定"), ("ja", "送る", "設定"),
            ("ko", "보내기", "설정"), ("es", "Enviar", "Ajustes"),
            ("fr", "Envoyer", "Réglages"), ("de", "Senden", "Einstellungen"),
            ("it", "Invia", "Impostazioni"), ("pt-BR", "Enviar", "Ajustes"),
            ("nl", "Verstuur", "Instellingen"), ("pl", "Wyślij", "Ustawienia"),
            ("tr", "Gönder", "Ayarlar"), ("ar", "إرسال", "الإعدادات"),
            ("hi", "भेजें", "सेटिंग्स"), ("id", "Kirim", "Pengaturan")
        ]
        for (code, send, settings) in languages {
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-dropack.language", code, "-dropack.appearance", "light"]
            app.launch()
            XCTAssertTrue(app.buttons["sendPhotosButton"].waitForExistence(timeout: 20), code)
            XCTAssertTrue(app.buttons["sendPhotosButton"].label.contains(send), "\(code): \(app.buttons["sendPhotosButton"].label)")
            capture("Home-\(code)")
            app.buttons["settingsButton"].tap()
            XCTAssertTrue(app.navigationBars[settings].waitForExistence(timeout: 5), code)
            capture("Settings-\(code)")
            app.terminate()
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
