import Foundation
import CoreGraphics
import UIKit
import XCTest

/// These tests execute the native app in Simulator. They verify navigation,
/// persisted projects, explicit hardware fallback, and the real SceneKit viewer.
/// Simulator cannot validate camera frames, LiDAR geometry, or measurement accuracy.
final class AtlasUITests: XCTestCase {
    /// Production entry, deliberately without the local-fixture bypass. No
    /// real account, email code, server token or simulated GPS is manufactured.
    @MainActor
    func testStaffEntryKeepsNewWorkClosedAndLocalExportAvailableBeforeLogin() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(element("staff.signIn",in:app).waitForExistence(timeout:20))
        XCTAssertFalse(element("projects.startCapture",in:app).exists)
        XCTAssertFalse(element("staff.task.open",in:app).exists)
        XCTAssertFalse(element("staff.work.start",in:app).exists)
        tap("staff.localRecords",in:app)
        XCTAssertTrue(app.navigationBars["Локальные записи"].waitForExistence(timeout:10))
        XCTAssertFalse(element("projects.startCapture",in:app).exists)
        screenshot("staff-before-login-local-originals",app:app)
        app.terminate()
        app.launch()
        XCTAssertTrue(element("staff.signIn",in:app).waitForExistence(timeout:20))
        XCTAssertFalse(element("projects.startCapture",in:app).exists)
    }

    @MainActor
    private func launch(seedMesh: Bool = false, seedCemetery: Bool = false, seedBuilding: Bool = false, seedTour: Bool = false, seedReview: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "--uitest-local-fixtures"]
        if seedMesh { app.launchArguments.append("--uitest-seed-mesh") }
        if seedCemetery { app.launchArguments.append("--uitest-seed-cemetery") }
        if seedBuilding { app.launchArguments.append("--uitest-seed-building") }
        if seedTour { app.launchArguments.append("--uitest-seed-tour") }
        if seedReview { app.launchArguments.append("--uitest-seed-review") }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let control = element(identifier, in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "Missing control: \(identifier)", file: file, line: line)
        XCTAssertTrue(control.isEnabled, "Disabled control: \(identifier)", file: file, line: line)
        XCTAssertTrue(control.isHittable, "Hidden control: \(identifier)", file: file, line: line)
        control.tap()
    }

    @MainActor
    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func createProject(in app: XCUIApplication) -> String {
        tap("projects.create", in: app)
        let field = element("project.name", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let name = "Runtime QA \(UUID().uuidString.prefix(8))"
        field.tap()
        field.typeText(name)
        tap("project.save", in: app)
        XCTAssertTrue(element("projects.startCapture", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        return name
    }

    @MainActor
    func testProjectSurvivesProcessRestart() {
        let app = launch()
        let name = createProject(in: app)
        screenshot("01-project-created", app: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15), "Saved project disappeared after restart")
        XCTAssertTrue(element("projects.startCapture", in: app).exists)
        screenshot("02-project-reopened", app: app)
    }

    @MainActor
    func testCaptureModesHaveVisibleFallbackAndRemainResponsive() {
        let app = launch()
        _ = createProject(in: app)
        tap("projects.startCapture", in: app)
        XCTAssertTrue(element("capture.unavailable", in: app).waitForExistence(timeout: 15),
                      "Simulator must explain missing LiDAR instead of leaving an empty camera")
        screenshot("03-capture-lidar-unavailable", app: app)

        tap("capture.mode.room", in: app)
        XCTAssertTrue(element("capture.unavailable", in: app).waitForExistence(timeout: 10))
        screenshot("04-capture-room-unavailable", app: app)

        tap("capture.mode.evidence", in: app)
        allowCameraPermissionIfShown()
        XCTAssertTrue(element("evidence.cameraUnavailable", in: app).waitForExistence(timeout: 15),
                      "Photo mode must show a visible camera fallback in Simulator")
        XCTAssertTrue(element("evidence.import", in: app).exists, "Photo import must remain available without a camera")
        screenshot("05-capture-photo-unavailable", app: app)

        // Repeated switching detects stalled preparation, disabled navigation,
        // and view/session lifetime crashes that a compile-only check misses.
        for _ in 0..<5 {
            tap("capture.mode.lidar", in: app)
            XCTAssertTrue(element("capture.unavailable", in: app).waitForExistence(timeout: 5))
            tap("capture.mode.room", in: app)
            XCTAssertTrue(element("capture.unavailable", in: app).waitForExistence(timeout: 5))
            tap("capture.mode.evidence", in: app)
            XCTAssertTrue(element("evidence.cameraUnavailable", in: app).waitForExistence(timeout: 5))
        }
        tap("capture.close", in: app)
        XCTAssertTrue(element("projects.startCapture", in: app).waitForExistence(timeout: 10),
                      "Capture screen must let the operator return to the project")
    }

    @MainActor
    func testFieldDeliveryDefaultsManualAndPersistsWithoutAnAccount() {
        let app = launch()
        let name = createProject(in: app)
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.fieldTransfer", in: app)
        scrollTo("transfer.mode", in: app)
        let picker = app.segmentedControls["transfer.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        let manual = picker.buttons["Вручную"]
        let automatic = picker.buttons["Автоматически"]
        waitUntilEnabled(manual)
        XCTAssertTrue(manual.isSelected, "An unconnected project must default to manual delivery")
        screenshot("11-transfer-manual-initial", app: app)

        automatic.tap()
        waitUntilEnabled(automatic)
        XCTAssertTrue(automatic.isSelected)
        let wifi = app.switches["transfer.wifiOnly"]
        XCTAssertTrue(wifi.waitForExistence(timeout: 10))
        waitUntilEnabled(wifi)
        if wifi.value as? String != "1" { wifi.tap(); waitUntilEnabled(wifi) }
        XCTAssertEqual(wifi.value as? String, "1")
        screenshot("12-transfer-auto-wifi", app: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.fieldTransfer", in: app)
        scrollTo("transfer.mode", in: app)
        let restored = app.segmentedControls["transfer.mode"]
        XCTAssertTrue(restored.waitForExistence(timeout: 15))
        let restoredAuto = restored.buttons["Автоматически"]
        waitUntilEnabled(restoredAuto)
        XCTAssertTrue(restoredAuto.isSelected, "Delivery choice disappeared after process restart")
        XCTAssertEqual(app.switches["transfer.wifiOnly"].value as? String, "1")
        restored.buttons["Вручную"].tap()
        waitUntilEnabled(restored.buttons["Вручную"])
        XCTAssertTrue(restored.buttons["Вручную"].isSelected)
        screenshot("13-transfer-restored-manual", app: app)

        scrollAndTap("transfer.createArchive", in: app, towardTop: true)
        XCTAssertTrue(element("transfer.shareArchive", in: app).waitForExistence(timeout: 30),
                      "The offline project must produce a real shareable archive without a team account")
        scrollTo("transfer.send", in: app)
        XCTAssertFalse(element("transfer.send", in: app).isEnabled,
                       "No server account must never look like an available cloud upload")
    }

    @MainActor
    func testFreeToolsUseTheSelectedProjectAndReturnFromCapture() {
        let app = launch()
        let name = createProject(in: app)
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        XCTAssertFalse(tabs.buttons["Бизнес"].exists, "The retired Business tab must not be exposed")
        XCTAssertFalse(tabs.buttons["Подписки"].exists, "Local tools must not have a subscription tab")

        let profile = tabs.buttons["Профиль"]
        XCTAssertTrue(profile.isHittable)
        profile.tap()
        XCTAssertTrue(app.staticTexts["TerraView"].waitForExistence(timeout: 10),
                      "The profile must show the shipping display name")
        XCTAssertTrue(app.buttons["Моя команда"].firstMatch.waitForExistence(timeout: 10),
                      "The workspace links must be visible before checking their contents")
        XCTAssertFalse(app.buttons["Тарифы и покупки"].exists,
                       "The profile must not send users to a purchase storefront")

        let tools = tabs.buttons["Съёмка"]
        XCTAssertTrue(tools.isHittable)
        tools.tap()
        XCTAssertTrue(element("tools.project", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(selectedProjectIsVisible(name, in: app),
                      "The tools workspace must use the project that was just created")
        XCTAssertTrue(element("tools.measurements", in: app).isEnabled,
                      "Measurement tools must be available without a purchase or team account")
        tap("tools.startCapture", in: app)
        XCTAssertTrue(element("capture.unavailable", in: app).waitForExistence(timeout: 15),
                      "Simulator capture must explain missing hardware")
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists,
                      "Capture must receive the selected project's exact name")
        tap("capture.close", in: app)
        XCTAssertTrue(element("tools.startCapture", in: app).waitForExistence(timeout: 10),
                      "Close must return to the tools workspace instead of trapping the user")
        XCTAssertTrue(element("tools.startCapture", in: app).isHittable)
        XCTAssertTrue(selectedProjectIsVisible(name, in: app),
                      "Closing capture must preserve the selected project")
        screenshot("14-free-tools", app: app)

        tabs.buttons["Проекты"].tap()
        XCTAssertTrue(element("projects.startCapture", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        tap("projects.openSelected", in: app)
        // A new project has no plan geometry. Verify these export actions are
        // reachable without claiming that an empty SVG is a valid floor plan.
        for identifier in ["export.svg", "export.csv", "export.kml"] {
            scrollTo(identifier, in: app)
            XCTAssertTrue(element(identifier, in: app).isEnabled,
                          "Export must be available without a subscription: \(identifier)")
        }
    }

    @MainActor
    private func selectedProjectIsVisible(_ name: String, in app: XCUIApplication) -> Bool {
        let picker = element("tools.project", in: app)
        return picker.label.contains(name) || (picker.value as? String)?.contains(name) == true ||
            app.staticTexts[name].firstMatch.exists
    }

    @MainActor
    private func openSeededCemeteryMap(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Демо · полевое обследование"].firstMatch.waitForExistence(timeout: 15),
                      "The labelled synthetic project must be stored through the normal project flow")
        tap("projects.openSelected", in: app)
        // iOS 26 can report an occluded lazy row as hittable even when its
        // centre lies behind the navigation bar. Require the whole real row.
        revealWholeControl(element("projects.cemetery", in: app), in: app)
        tap("projects.cemetery", in: app)
        XCTAssertTrue(app.staticTexts["Учебное кладбище"].firstMatch.waitForExistence(timeout: 15),
                      "Fieldwork must load the actual saved cemetery rather than an empty demonstration screen")
        tap("cemetery.map", in: app)
        XCTAssertTrue(element("map.layers", in: app).waitForExistence(timeout: 15))
    }

    @MainActor
    private func openMapCard(_ suffix: String, in app: XCUIApplication) {
        let identifier = "map.card.A71A5000-1234-4000-8000-000000000" + suffix
        let card = element(identifier, in: app)
        let strip = app.scrollViews["map.featureStrip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "The real lazy object strip is missing")
        guard strip.exists else { return }
        // A lazy stack creates distant cards after they enter its viewport.
        // Search the strip before requiring a card's accessibility element.
        for attempt in 0..<12 {
            if card.exists && card.isHittable {
                card.tap()
                XCTAssertTrue(element("burial.status.summary", in: app).waitForExistence(timeout: 15),
                              "The saved grave must open its real burial card")
                return
            }
            if attempt < 6 { strip.swipeLeft() } else { strip.swipeRight() }
        }
        XCTFail("The saved map card cannot be opened: \(identifier)")
    }

    @MainActor
    private func waitForAbsence(_ control: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 15), .completed, file: file, line: line)
    }

    @MainActor
    private func scrollToControl(_ control: XCUIElement, in app: XCUIApplication,
                                 towardTop: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 {
            if control.exists && control.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Could not reveal control: \(control)", file: file, line: line)
    }

    @MainActor
    private func revealWholeDrawing(_ drawing: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 8 : window.maxY - 40
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<10 {
            if drawing.exists, drawing.frame.minY >= top, drawing.frame.maxY <= bottom { return }
            let upward = drawing.exists ? drawing.frame.maxY > bottom : true
            let start = origin.withOffset(CGVector(dx: window.midX - window.minX, dy: window.height * 0.65))
            let finish = origin.withOffset(CGVector(dx: window.midX - window.minX, dy: window.height * 0.65 + (upward ? -160 : 160)))
            start.press(forDuration: 0.05, thenDragTo: finish)
        }
        XCTFail("The complete drawing must be visible between navigation and tabs for real pixel and screenshot checks")
    }

    @MainActor
    private func assertUnknownBurialIdentity(in app: XCUIApplication) {
        let identity = element("burial.identity.summary", in: app)
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        XCTAssertEqual(identity.label, "Личность неизвестна",
                       "An observed or confirmed burial must never invent a person's identity")
        scrollToControl(element("burial.person.add", in: app), in: app)
        XCTAssertTrue(app.staticTexts["Сведения о людях пока не добавлены."].exists)
        XCTAssertFalse(app.textFields["Фамилия, имя, отчество — если известны"].exists,
                       "The app must not create a person when only an inscription or anomaly is recorded")
    }

    @MainActor
    func testGeographicMapLayersAndSearchRemainAvailableWithoutSensorOrNetworkResults() {
        let app = launch(seedCemetery: true)
        openSeededCemeteryMap(in: app)
        let grave = element("map.card.A71A5000-1234-4000-8000-000000000103", in: app)
        XCTAssertTrue(grave.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["WGS84 · карта местности"].exists)
        XCTAssertTrue(element("map.locate", in: app).isEnabled)
        XCTAssertTrue(element("map.track", in: app).isEnabled)
        XCTAssertFalse(element("map.locationStatus", in: app).exists,
                       "Opening the map must not claim that a GPS observation has been acquired")
        screenshot("17-field-map", app: app)

        tap("map.layers", in: app)
        let graveLayer = app.switches["map.layer.grave"]
        scrollToControl(graveLayer, in: app)
        XCTAssertEqual(graveLayer.value as? String, "1")
        // SwiftUI exposes the complete labelled row as a Switch. Its centre
        // is the label; tap the visible native toggle at the right of the row.
        graveLayer.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let hiddenLayer = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: graveLayer)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenLayer], timeout: 10), .completed,
                       "The actual grave switch must turn off before checking its map cards")
        XCTAssertEqual(graveLayer.value as? String, "0")
        screenshot("20-map-layers", app: app)
        app.navigationBars["Слои карты"].buttons["Готово"].tap()
        waitForAbsence(grave)

        tap("map.layers", in: app)
        let restoredLayer = app.switches["map.layer.grave"]
        scrollToControl(restoredLayer, in: app)
        restoredLayer.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let shownLayer = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: restoredLayer)
        XCTAssertEqual(XCTWaiter.wait(for: [shownLayer], timeout: 10), .completed,
                       "The actual grave switch must turn on before checking its map cards")
        XCTAssertEqual(restoredLayer.value as? String, "1")
        app.navigationBars["Слои карты"].buttons["Готово"].tap()
        XCTAssertTrue(grave.waitForExistence(timeout: 10), "Restoring a layer must restore its saved map cards")

        tap("map.search", in: app)
        XCTAssertTrue(element("map.search.query", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Введите название. Поиск Apple Maps требует подключения к интернету."].exists,
                      "The search must explain its network requirement before any address is requested")
        screenshot("20b-map-search", app: app)
        app.navigationBars["Поиск на карте"].buttons["Закрыть"].tap()
        XCTAssertTrue(element("map.layers", in: app).waitForExistence(timeout: 10),
                      "Closing search must return to the same saved map without requiring a network result")
        XCTAssertTrue(grave.exists)
    }

    @MainActor
    func testUnknownBurialInscriptionAndCommentsSurviveRestartWithoutInventingIdentity() {
        let app = launch(seedCemetery: true)
        openSeededCemeteryMap(in: app)
        openMapCard("103", in: app)
        XCTAssertEqual(element("burial.status.summary", in: app).label, "Захоронение подтверждено")
        assertUnknownBurialIdentity(in: app)
        let marker = String(UUID().uuidString.prefix(8))
        let inscription = "QA-TRANSCRIPTION-\(marker)"
        let comment = "QA-COMMENT-\(marker)"
        let inscriptionField = element("burial.inscription", in: app)
        scrollToControl(inscriptionField, in: app)
        inscriptionField.tap(); inscriptionField.typeText(inscription)
        let keyboardDone = app.buttons["burial.keyboardDone"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 10), "The card must provide a visible way to finish multiline text entry")
        keyboardDone.tap()
        waitForAbsence(app.keyboards.firstMatch)
        let notesField = element("burial.notes", in: app)
        scrollToControl(notesField, in: app)
        notesField.tap(); notesField.typeText(comment)
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 10))
        keyboardDone.tap()
        waitForAbsence(app.keyboards.firstMatch)
        tap("burial.save", in: app)
        waitForAbsence(element("burial.save", in: app))

        app.terminate()
        app.launch()
        openSeededCemeteryMap(in: app)
        openMapCard("103", in: app)
        XCTAssertEqual(element("burial.status.summary", in: app).label, "Захоронение подтверждено")
        assertUnknownBurialIdentity(in: app)
        let restoredInscription = element("burial.inscription", in: app)
        scrollToControl(restoredInscription, in: app)
        XCTAssertTrue((restoredInscription.value as? String ?? "").contains(inscription),
                      "The transcription draft disappeared after a real process restart")
        let restoredNotes = element("burial.notes", in: app)
        scrollToControl(restoredNotes, in: app)
        XCTAssertTrue((restoredNotes.value as? String ?? "").contains(comment),
                      "The operator's comments disappeared after a real process restart")
        scrollToControl(element("burial.status.summary", in: app), in: app, towardTop: true)
        screenshot("18-burial-unknown", app: app)

        let historyButton = app.buttons["burial.history"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        // History is now a fixed native bottom-toolbar action, reachable from
        // every position in the long card rather than a distant Form row.
        let historyFullyVisible = historyButton.isHittable
            && window.insetBy(dx: 0, dy: 8).contains(historyButton.frame)
        XCTAssertTrue(historyFullyVisible, "The fixed history action must be completely visible before tapping")
        guard historyFullyVisible else { return }
        XCTAssertTrue(historyButton.isEnabled)
        historyButton.tap()
        XCTAssertTrue(app.navigationBars["История карточки"].waitForExistence(timeout: 10))
        let revisions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Версия "))
        XCTAssertTrue(revisions.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(revisions.count, 2, "A saved card edit must create a durable revision")
        let latest = revisions.element(boundBy: revisions.count - 1)
        scrollToControl(latest, in: app)
        latest.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", inscription)).firstMatch.waitForExistence(timeout: 10),
                      "The history must contain the actual saved inscription")
        app.navigationBars["История карточки"].buttons["Готово"].tap()
        tap("burial.cancel", in: app)
    }

    @MainActor
    func testCandidateRejectionIsReversibleAndNeverConfirmsAnUnknownPerson() {
        let app = launch(seedCemetery: true)
        openSeededCemeteryMap(in: app)
        openMapCard("104", in: app)
        XCTAssertEqual(element("burial.status.summary", in: app).label, "Возможное захоронение · нужна проверка")
        assertUnknownBurialIdentity(in: app)
        let reject = app.buttons["Отклонить предположение"]
        scrollToControl(reject, in: app)
        reject.tap()
        let confirmation = app.buttons["Подтвердить"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.tap()
        waitForAbsence(element("burial.save", in: app))
        let candidate = element("map.card.A71A5000-1234-4000-8000-000000000104", in: app)
        waitForAbsence(candidate)

        tap("map.layers", in: app)
        let inactive = app.switches["map.showInactive"]
        XCTAssertTrue(inactive.waitForExistence(timeout: 10))
        XCTAssertEqual(inactive.value as? String, "0")
        inactive.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let inactiveShown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: inactive)
        XCTAssertEqual(XCTWaiter.wait(for: [inactiveShown], timeout: 10), .completed,
                       "Show inactive must turn on before opening the rejected record")
        XCTAssertEqual(inactive.value as? String, "1")
        app.navigationBars["Слои карты"].buttons["Готово"].tap()
        openMapCard("104", in: app)
        XCTAssertEqual(element("burial.status.summary", in: app).label, "Предположение отклонено")
        assertUnknownBurialIdentity(in: app)
        let restore = app.buttons["Восстановить карточку"]
        scrollToControl(restore, in: app)
        restore.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.tap()
        waitForAbsence(element("burial.save", in: app))

        tap("map.layers", in: app)
        let restoredInactive = app.switches["map.showInactive"]
        XCTAssertEqual(restoredInactive.value as? String, "1")
        restoredInactive.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let inactiveHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: restoredInactive)
        XCTAssertEqual(XCTWaiter.wait(for: [inactiveHidden], timeout: 10), .completed,
                       "Show inactive must turn off before checking the restored candidate")
        XCTAssertEqual(restoredInactive.value as? String, "0")
        app.navigationBars["Слои карты"].buttons["Готово"].tap()
        openMapCard("104", in: app)
        XCTAssertEqual(element("burial.status.summary", in: app).label, "Возможное захоронение · нужна проверка",
                       "Restoring a rejected anomaly must preserve its unconfirmed burial status")
        assertUnknownBurialIdentity(in: app)
        scrollToControl(element("burial.status.summary", in: app), in: app, towardTop: true)
        screenshot("19-burial-candidate-restored", app: app)
        tap("burial.cancel", in: app)
    }

    @MainActor
    func testEmptyRoomExplainsRealSimulatorLimitationAndReturnsToTheProject() {
        let app = launch()
        let name = createProject(in: app)
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.emptyRoom", in: app)
        let unavailable = element("emptyRoom.unavailable", in: app)
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15),
                      "The designer flow must explain unsupported RoomPlan instead of pretending to create geometry")
        scrollToControl(unavailable, in: app)
        XCTAssertTrue(unavailable.isHittable)
        let dimensions = app.switches["emptyRoom.dimensions"]
        let storage = app.switches["emptyRoom.keepStorage"]
        scrollToControl(dimensions, in: app, towardTop: true)
        XCTAssertEqual(dimensions.value as? String, "1")
        scrollToControl(storage, in: app)
        XCTAssertEqual(storage.value as? String, "0")
        storage.tap()
        XCTAssertEqual(storage.value as? String, "1", "Keeping storage must be the operator's explicit choice")
        storage.tap()
        XCTAssertEqual(storage.value as? String, "0")
        scrollToControl(unavailable, in: app)
        screenshot("21-empty-room-unavailable", app: app)
        tap("emptyRoom.close", in: app)
        XCTAssertTrue(element("projects.emptyRoom", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars[name].firstMatch.exists,
                      "Closing the designer flow must return to its exact project")
    }

    @MainActor
    func testBuildingGroupsSavedFloorsAndDimensionsChangeTheRealDrawing() {
        let app = launch(seedBuilding: true)
        XCTAssertTrue(app.staticTexts["Демо · этажи здания"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.buildingPlans", in: app)
        XCTAssertTrue(element("building.catalog", in: app).waitForExistence(timeout: 15))
        let secondPlan = app.buttons["building.plan.A71A5000-1234-4000-8000-000000000204"].firstMatch
        XCTAssertTrue(secondPlan.waitForExistence(timeout: 10),
                      "The saved second-floor plan must expose its own navigation control")
        scrollToControl(secondPlan, in: app)
        XCTAssertTrue(element("building.floor.2", in: app).exists,
                      "A saved floorIndex must produce its actual floor group")
        let firstPlan = app.buttons["building.plan.A71A5000-1234-4000-8000-000000000203"].firstMatch
        scrollToControl(firstPlan, in: app)
        XCTAssertTrue(element("building.floor.1", in: app).exists)
        XCTAssertTrue(firstPlan.label.contains("Учебный обмер · этаж 1"),
                      "The exact saved plan UUID must name its real first-floor plan")
        screenshot("22-building-plans", app: app)
        firstPlan.tap()
        XCTAssertTrue(app.staticTexts["Учебный обмер · этаж 1"].firstMatch.waitForExistence(timeout: 15),
                      "Opening a catalog plan must select that exact saved plan, not an arbitrary floor")
        let dimensions = app.switches["floorPlan.dimensions"]
        scrollToControl(dimensions, in: app)
        XCTAssertEqual(dimensions.value as? String, "1")
        let drawing = element("floorPlan.drawing", in: app)
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        revealWholeDrawing(drawing, in: app)
        XCTAssertTrue(drawing.label.contains("1 комнат") && drawing.label.contains("4 стен"),
                      "The viewport must receive the actual persisted room and walls")
        guard let withDimensions = drawingPixels(drawing.screenshot().image) else {
            XCTFail("The real floor-plan viewport did not produce a readable image")
            return
        }
        dimensions.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let hiddenDimensions = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: dimensions)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenDimensions], timeout: 5), .completed,
                       "Tapping the dimension switch thumb must hide the actual drawing annotations")
        XCTAssertEqual(dimensions.value as? String, "0")
        guard let withoutDimensions = drawingPixels(drawing.screenshot().image) else {
            XCTFail("The floor-plan viewport disappeared after hiding dimensions")
            return
        }
        XCTAssertGreaterThan(changedDrawingPixels(withDimensions, withoutDimensions), 20,
                             "Hiding dimensions must change the native drawing itself, not just the switch")
        dimensions.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let visibleDimensions = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: dimensions)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleDimensions], timeout: 5), .completed,
                       "Tapping the dimension switch thumb must restore the drawing annotations")
        XCTAssertEqual(dimensions.value as? String, "1")
        revealWholeDrawing(drawing, in: app)
        screenshot("22b-plan-dimensions", app: app)
        let panMode = app.switches["floorPlan.panMode"]
        scrollToControl(panMode, in: app)
        XCTAssertEqual(panMode.value as? String, "0",
                       "The drawing must allow page scrolling until the operator explicitly enables panning")
        let room = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "floorPlan.room.", "Учебная комната")).firstMatch
        scrollToControl(room, in: app)
        XCTAssertTrue(room.exists && room.label.contains("Учебная комната"),
                      "The room must still exist after the presentation-only dimension changes")
        let roomIdentifier = room.identifier

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Демо · этажи здания"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.buildingPlans", in: app)
        let reopenedPlan = app.buttons["building.plan.A71A5000-1234-4000-8000-000000000203"].firstMatch
        scrollToControl(reopenedPlan, in: app)
        XCTAssertTrue(element("building.floor.1", in: app).exists,
                      "Floor grouping must survive restarting the process")
        reopenedPlan.tap()
        XCTAssertTrue(app.staticTexts["Учебный обмер · этаж 1"].firstMatch.waitForExistence(timeout: 15))
        let restoredRoom = app.buttons[roomIdentifier].firstMatch
        scrollToControl(restoredRoom, in: app)
        XCTAssertTrue(restoredRoom.exists && restoredRoom.label.contains("Учебная комната"),
                      "The same saved room UUID and name must survive restarting the process")
    }

    @MainActor
    func testTourLoadsOriginalsMovesBetweenStationsAndOpensTheSameBurialCard() {
        let app = launch(seedCemetery: true, seedTour: true)
        XCTAssertTrue(app.staticTexts["Демо · полевое обследование"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.tour", in: app)
        XCTAssertTrue(element("tour.play", in: app).waitForExistence(timeout: 15))
        tap("tour.play", in: app)
        XCTAssertTrue(app.staticTexts["1 / 2 · Учебная остановка 1"].waitForExistence(timeout: 15))
        let card = element("tour.feature.card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The central reticle must select the saved operator contour")
        XCTAssertTrue(app.staticTexts["Участок 001"].firstMatch.exists)
        XCTAssertEqual(element("tour.feature.status", in: app).label,
                       "Захоронение подтверждено · контур в кадре отметил оператор")
        screenshot("23-tour-contours", app: app)
        app.buttons["Вперёд"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 / 2 · Учебная остановка 2"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("tour.feature.card", in: app).waitForExistence(timeout: 15))
        app.buttons["Назад"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 / 2 · Учебная остановка 1"].waitForExistence(timeout: 15))
        tap("tour.feature.card", in: app)
        XCTAssertTrue(element("burial.status.summary", in: app).waitForExistence(timeout: 15))
        XCTAssertEqual(element("burial.label", in: app).value as? String, "Участок 001", "A contour must open its linked UUID, not create another grave")
        screenshot("24-tour-linked-card", app: app)
        tap("burial.cancel", in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Демо · полевое обследование"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.tour", in: app)
        tap("tour.play", in: app)
        XCTAssertTrue(app.staticTexts["1 / 2 · Учебная остановка 1"].waitForExistence(timeout: 15), "The original-backed tour must survive restart")
    }

    private func drawingPixels(_ image: UIImage) -> [UInt8]? {
        guard let source = image.cgImage else { return nil }
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        return drawn ? pixels : nil
    }

    private func changedDrawingPixels(_ first: [UInt8], _ second: [UInt8]) -> Int {
        guard first.count == second.count else { return 0 }
        var changed = 0
        for offset in stride(from: 0, to: first.count, by: 4) {
            let difference = abs(Int(first[offset]) - Int(second[offset])) +
                abs(Int(first[offset + 1]) - Int(second[offset + 1])) +
                abs(Int(first[offset + 2]) - Int(second[offset + 2]))
            if difference > 24 { changed += 1 }
        }
        return changed
    }

    @MainActor
    func testGuidedObjectCaptureExplainsSimulatorSupportAndReturns() {
        let app = launch()
        let name = createProject(in: app)
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.objectCapture", in: app)
        let unavailable = element("objectCapture.unavailable", in: app)
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15),
                      "Guided object capture must show the real hardware limitation in Simulator")
        XCTAssertTrue(unavailable.isHittable, "The unsupported-device explanation must be visible")
        XCTAssertTrue(element("objectCapture.close", in: app).isEnabled,
                      "Unsupported hardware must not trap the user in the capture screen")
        screenshot("15-object-unavailable", app: app)
        tap("objectCapture.close", in: app)
        XCTAssertTrue(element("projects.objectCapture", in: app).waitForExistence(timeout: 10),
                      "Close must return to the same project")
        XCTAssertTrue(app.navigationBars[name].firstMatch.exists,
                      "Returning from object capture must preserve the current project")
    }

    @MainActor
    private func waitUntilEnabled(_ control: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    private func scrollTo(_ identifier: String, in app: XCUIApplication, towardTop: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<7 {
            let control = element(identifier, in: app)
            if control.exists && control.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Could not reveal control: \(identifier)", file: file, line: line)
    }

    @MainActor
    private func scrollAndTap(_ identifier: String, in app: XCUIApplication, towardTop: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        scrollTo(identifier, in: app, towardTop: towardTop, file: file, line: line)
        tap(identifier, in: app, file: file, line: line)
    }

    @MainActor
    func testThreeDViewerRotatesWalksAndResets() {
        let app = launch(seedMesh: true)
        var surface = element("viewer.scene", in: app)
        if !surface.waitForExistence(timeout: 2) {
            if !element("project.viewer", in: app).waitForExistence(timeout: 2) {
                tap("projects.openSelected", in: app)
            }
            tap("project.viewer", in: app)
            surface = element("viewer.scene", in: app)
        }
        XCTAssertTrue(surface.waitForExistence(timeout: 25), "The fixture OBJ must load in the real SceneKit renderer")
        XCTAssertTrue(surface.isHittable)
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "rendered"), object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed,
                       "SceneKit must render an actual first frame before the model is ready")
        assertVisibleGeometry(surface, app: app, stage: "initial-orbit")
        screenshot("06-viewer-orbit-initial", app: app)

        let originalOrbit = surface.value as? String ?? ""
        XCTAssertTrue(originalOrbit.contains("orbit"), "Viewer must expose its current camera mode")
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        assertCameraChanged(surface, from: originalOrbit)
        assertVisibleGeometry(surface, app: app, stage: "rotated-orbit")
        screenshot("07-viewer-orbit-rotated", app: app)

        XCUIDevice.shared.press(.home)
        app.activate()
        surface = element("viewer.scene", in: app)
        XCTAssertTrue(surface.waitForExistence(timeout: 15), "Viewer disappeared after background and foreground")
        let resumedFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "rendered"), object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [resumedFrame], timeout: 10), .completed)
        assertVisibleGeometry(surface, app: app, stage: "foreground-orbit")
        screenshot("07b-viewer-foreground", app: app)

        tap("viewer.mode.walkthrough", in: app)
        XCTAssertTrue((surface.value as? String ?? "").contains("walk"))
        let originalWalk = surface.value as? String ?? ""
        tap("viewer.move.forward", in: app)
        assertCameraChanged(surface, from: originalWalk)
        assertVisibleGeometry(surface, app: app, stage: "walk", requireSpatialContrast: true)
        screenshot("08-viewer-walk-forward", app: app)

        tap("viewer.reset", in: app)
        XCTAssertTrue((surface.value as? String ?? "").contains("walk"))
        tap("viewer.mode.orbit", in: app)
        XCTAssertTrue((surface.value as? String ?? "").contains("orbit"))
        assertVisibleGeometry(surface, app: app, stage: "reset-orbit")
        screenshot("09-viewer-reset", app: app)

        guard let originalTriangles = triangleCount(surface.value as? String ?? "") else {
            XCTFail("The real viewport must report its rendered triangle count")
            return
        }
        XCTAssertGreaterThan(originalTriangles, 0)
        tap("viewer.section", in: app)
        waitForSection(surface, enabled: true, originalTriangles: originalTriangles)
        XCTAssertTrue(element("viewer.section.height", in: app).waitForExistence(timeout: 10),
                      "A section must expose its adjustable clipping height")
        assertVisibleGeometry(surface, app: app, stage: "section-orbit")
        screenshot("16-viewer-section", app: app)
        tap("viewer.section", in: app)
        waitForSection(surface, enabled: false, originalTriangles: originalTriangles)
        assertVisibleGeometry(surface, app: app, stage: "section-restored-orbit")

        tap("viewer.measure", in: app)
        assertMeasuredSurfaceDistance(surface, app: app)
        tap("viewer.measure", in: app)
    }

    private func triangleCount(_ pose: String) -> Int? {
        guard let range = pose.range(of: "triangles:") else { return nil }
        return Int(pose[range.upperBound...].split(separator: " ").first ?? "")
    }

    @MainActor
    private func waitForSection(_ surface: XCUIElement, enabled: Bool, originalTriangles: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let pose = surface.value as? String ?? ""
            if pose.contains(enabled ? "section:on" : "section:off"),
               let count = triangleCount(pose), count > 0,
               enabled ? count != originalTriangles : count == originalTriangles { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("Section must change the actual rendered mesh and restore its original triangles when disabled. "
                + "Viewport: \(surface.value as? String ?? "missing"); source triangles: \(originalTriangles)",
                file: file, line: line)
    }

    @MainActor
    private func assertMeasuredSurfaceDistance(_ surface: XCUIElement, app: XCUIApplication,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let result = element("viewer.measurementValue", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 10), file: file, line: line)
        // Find real ray hits on the synthetic room. This central grid excludes
        // the top guidance and bottom reset control and tolerates viewport sizes.
        let points = [CGVector(dx: 0.5, dy: 0.6), CGVector(dx: 0.65, dy: 0.6),
                      CGVector(dx: 0.35, dy: 0.6), CGVector(dx: 0.5, dy: 0.5),
                      CGVector(dx: 0.65, dy: 0.5), CGVector(dx: 0.35, dy: 0.5),
                      CGVector(dx: 0.5, dy: 0.7), CGVector(dx: 0.65, dy: 0.7),
                      CGVector(dx: 0.35, dy: 0.7)]
        var firstHit: Int?
        for (index, point) in points.enumerated() {
            surface.coordinate(withNormalizedOffset: point).tap()
            if waitForLabel(result, containing: "A отмечена", timeout: 1) {
                firstHit = index
                break
            }
        }
        guard let firstHit else {
            XCTFail("No first measurement ray hit the fixture's visible surface: \(result.label)", file: file, line: line)
            return
        }
        var measured = false
        for (index, point) in points.enumerated() where index != firstHit {
            surface.coordinate(withNormalizedOffset: point).tap()
            if waitForLabel(result, containing: "расстояние по прямой", timeout: 1) {
                measured = true
                break
            }
        }
        XCTAssertTrue(measured, "A second real surface hit must calculate a distance: \(result.label)",
                      file: file, line: line)
        let label = result.label
        let numeric = label.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init) ?? ""
        let distance = Double(numeric.replacingOccurrences(of: ",", with: "."))
        XCTAssertTrue(distance.map { $0 > 0.001 && $0 < 12 } ?? false,
                      "Two distinct points within the 8 × 3 × 6 fixture must have a finite, nonzero distance: \(label)",
                      file: file, line: line)
        // Generic OBJ has no guaranteed unit metadata. An explicit unknown
        // source unit is honest; the fixture must never gain a fake ARKit marker.
        XCTAssertTrue(label.contains(" м ") || label.contains(" ед."),
                      "Measurement must label metres or explicitly unknown source units: \(label)",
                      file: file, line: line)
    }

    @MainActor
    private func waitForLabel(_ control: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if control.label.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return control.label.contains(text)
    }

    @MainActor
    private func assertCameraChanged(_ surface: XCUIElement, from value: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let previous = cameraCoordinates(value)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let current = cameraCoordinates(surface.value as? String ?? "")
            if current.contains(" x:") && current != previous { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("Camera controls did not move the rendered viewpoint", file: file, line: line)
    }

    private func cameraCoordinates(_ value: String) -> String {
        // A preparing/rendered lifecycle transition is not camera movement.
        value.replacingOccurrences(of: " rendered ", with: " ")
            .replacingOccurrences(of: " preparing ", with: " ")
    }

    private struct RenderProbe {
        let materialFraction: Double
        let spatialContrast: Double
        let sharpEdgeCount: Int
    }

    @MainActor
    private func assertVisibleGeometry(_ surface: XCUIElement, app: XCUIApplication, stage: String,
                                       requireSpatialContrast: Bool = false,
                                       file: StaticString = #filePath, line: UInt = #line) {
        // Pose values alone previously passed while the initial real viewport
        // stayed black. Probe only the fixture's central rendered area, excluding
        // the guidance and reset overlays; no exact pixel/color baseline is used.
        let deadline = Date().addingTimeInterval(10)
        var probe: RenderProbe?
        repeat {
            probe = renderProbe(surface.screenshot().image)
            if let probe, probe.materialFraction >= 0.01,
               !requireSpatialContrast || (probe.spatialContrast >= 12 && probe.sharpEdgeCount >= 8) {
                print("Native viewport \(stage): visible fraction \(probe.materialFraction), spatial contrast \(probe.spatialContrast), sharp edges \(probe.sharpEdgeCount)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        screenshot("viewer-\(stage)-render-failure", app: app)
        XCTFail("Fixture viewport \(stage) has no visible geometry or room context. "
                + "Material fraction: \(probe?.materialFraction ?? 0); spatial contrast: \(probe?.spatialContrast ?? 0); sharp edges: \(probe?.sharpEdgeCount ?? 0). "
                + "A changing camera pose or lighting gradient must not hide missing room structure.", file: file, line: line)
    }

    @MainActor
    private func renderProbe(_ screenshot: UIImage) -> RenderProbe? {
        guard let original = screenshot.cgImage else { return nil }
        let crop = CGRect(x: CGFloat(original.width) * 0.1, y: CGFloat(original.height) * 0.25,
                          width: CGFloat(original.width) * 0.8, height: CGFloat(original.height) * 0.6).integral
        guard let region = original.cropping(to: crop) else { return nil }
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.interpolationQuality = .medium
            context.draw(region, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            let rgba = buffer.bindMemory(to: UInt8.self)
            var visible = 0
            var grid = [Double](repeating: 0, count: 16)
            var luminances = [Double](repeating: 0, count: side * side)
            var sharpEdges = 0
            for y in 0..<side {
                for x in 0..<side {
                    let offset = (y * side + x) * 4
                    let red = Double(rgba[offset]), green = Double(rgba[offset + 1]), blue = Double(rgba[offset + 2])
                    if max(red, green, blue) > 80 { visible += 1 }
                    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let index = y * side + x
                    luminances[index] = luminance
                    grid[(y / 32) * 4 + x / 32] += luminance
                    // Both rejected native frames had zero local jumps >12,
                    // despite the later lighting gradient passing grid contrast.
                    // A real room crease must span several sampled neighbors;
                    // the crop excludes all guidance and reset controls.
                    if x > 0 && abs(luminance - luminances[index - 1]) > 12 { sharpEdges += 1 }
                    if y > 0 && abs(luminance - luminances[index - side]) > 12 { sharpEdges += 1 }
                }
            }
            let means = grid.map { $0 / 1024 }
            let contrast = (means.max() ?? 0) - (means.min() ?? 0)
            return RenderProbe(materialFraction: Double(visible) / Double(side * side), spatialContrast: contrast,
                               sharpEdgeCount: sharpEdges)
        }
    }

    @MainActor
    private func allowCameraPermissionIfShown() {
        // Most CI runtimes accept the simctl privacy grant. If a runtime still
        // presents the real system sheet, answer the explicit permission choice.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        for title in ["Allow", "OK", "Разрешить", "Allow While Using App", "При использовании приложения"] {
            let button = alert.buttons[title]
            if button.exists { button.tap(); return }
        }
        XCTFail("Unexpected system permission alert: \(alert.debugDescription)")
    }

    @MainActor
    private func enter(_ value: String, identifier: String, in app: XCUIApplication) {
        let field = element(identifier, in: app)
        // These fields precede the source/measurement sections. A lazy Form
        // removes their accessibility elements after a lower picker is used.
        let fieldStartsNearTop = identifier == "emptyRoom.review.note" || identifier.hasSuffix(".label")
        revealWholeControl(field, in: app, towardTopWhenMissing: fieldStartsNearTop)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Tapping the fully visible field must focus it before text entry")
        if let previous = field.value as? String, !previous.isEmpty,
           previous != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText(value)
        if app.keyboards.firstMatch.exists {
            let doneIDs = ["measurement.editor.keyboardDone", "emptyRoom.review.keyboardDone", "stations.manual.keyboardDone",
                           "collaboration.setup.keyboardDone", "collaboration.cell.keyboardDone"]
            let done = doneIDs.map { element($0, in: app) }.first { $0.exists && $0.isHittable }
            XCTAssertNotNil(done, "Text entry must provide a visible keyboard completion action")
            done?.tap()
            waitForAbsence(app.keyboards.firstMatch)
        }
    }

    @MainActor
    private func revealWholeControl(_ control: XCUIElement, in app: XCUIApplication,
                                    towardTopWhenMissing: Bool = false,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        var lastViewport = CGRect.zero
        for _ in 0..<20 {
            let top = app.navigationBars.allElementsBoundByIndex
                // Presented sheets keep the underlying stack's large bars in
                // the accessibility tree. Their rectangles overlap this window
                // even though they cannot receive a touch through the sheet.
                .filter { $0.exists && $0.isHittable && $0.frame.intersects(window) }
                .map { $0.frame.maxY + 8 }.max() ?? window.minY + 60
            var bottom = window.maxY - 40
            for bar in app.tabBars.allElementsBoundByIndex + app.toolbars.allElementsBoundByIndex {
                if bar.exists && bar.isHittable && bar.frame.midY > window.midY {
                    bottom = min(bottom, bar.frame.minY - 8)
                }
            }
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 8) }
            let viewport = CGRect(x: window.minX, y: top, width: window.width,
                                  height: max(1, bottom - top))
            lastViewport = viewport
            let frame = control.exists ? control.frame : CGRect.zero
            let usableFrame = frame.minX.isFinite && frame.minY.isFinite &&
                frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
            if control.exists && usableFrame && control.isHittable && viewport.contains(frame) { return }
            let towardTop = control.exists && usableFrame ? frame.minY < viewport.minY : towardTopWhenMissing
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let distance = min(300, viewport.height * 0.42)
            let startY = viewport.minY + viewport.height * (towardTop ? 0.38 : 0.68)
            let start = origin.withOffset(CGVector(dx: viewport.midX - window.minX, dy: startY - window.minY))
            let finish = origin.withOffset(CGVector(dx: viewport.midX - window.minX,
                dy: startY - window.minY + (towardTop ? distance : -distance)))
            start.press(forDuration: 0.05, thenDragTo: finish)
        }
        let barDiagnostics = app.navigationBars.allElementsBoundByIndex.map {
            "\($0.label): frame=\($0.frame), hittable=\($0.isHittable)"
        }.joined(separator: "; ")
        let finalFrame = control.exists ? control.frame : CGRect.zero
        XCTFail("The complete control did not enter the visible content viewport: \(control); "
                + "controlFrame=\(finalFrame), viewport=\(lastViewport), bars=[\(barDiagnostics)]", file: file, line: line)
    }

    @MainActor
    private func confirmSwitch(_ identifier: String, in app: XCUIApplication) {
        let control = app.switches[identifier]
        revealWholeControl(control, in: app, towardTopWhenMissing: true)
        if control.value as? String != "1" {
            // SwiftUI exposes the label and thumb as one switch. Its centre can
            // fall on descriptive text, so touch the actual trailing thumb.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 5), .completed,
                       "Operator confirmation must actually change the switch value")
    }

    @MainActor
    func testManualSurveyPersistsItsStationsAndMeasuresTheActualBoundary() {
        let app = launch()
        let name = createProject(in: app)
        app.tabBars.buttons["Карта"].tap()
        tap("map.stations", in: app)
        let manual = element("stations.addManual", in: app)
        XCTAssertTrue(manual.waitForExistence(timeout: 15))
        waitUntilEnabled(manual)
        XCTAssertFalse(element("stations.addGPS", in: app).isEnabled,
                       "GPS coordinates must not be silently inserted into a local metre frame")
        for point in [("0", "0"), ("4", "0"), ("0", "3")] {
            scrollAndTap("stations.addManual", in: app, towardTop: true)
            enter(point.0, identifier: "stations.manual.first", in: app)
            enter(point.1, identifier: "stations.manual.second", in: app)
            tap("stations.manual.save", in: app)
            waitForAbsence(element("stations.manual.save", in: app))
        }
        let third = element("stations.label.A003", in: app)
        scrollToControl(third, in: app)
        XCTAssertTrue(third.exists)
        screenshot("25-survey-stations", app: app)
        scrollAndTap("stations.preview", in: app)
        let area = element("stations.area", in: app)
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        XCTAssertTrue(area.label.replacingOccurrences(of: ",", with: ".").contains("6.0"),
                      "The actual 3-4-5 triangular boundary must measure 6 square metres")
        XCTAssertTrue(element("stations.perimeter", in: app).label.replacingOccurrences(of: ",", with: ".").contains("12.0"))
        screenshot("26-survey-boundary", app: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15))
        app.tabBars.buttons["Карта"].tap()
        tap("map.stations", in: app)
        scrollToControl(element("stations.label.A003", in: app), in: app)
        XCTAssertTrue(element("stations.label.A003", in: app).exists,
                      "The station journal must survive an actual process restart")
        scrollAndTap("stations.preview", in: app)
        XCTAssertTrue(element("stations.area", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("stations.area", in: app).label.replacingOccurrences(of: ",", with: ".").contains("6.0"))
    }

    @MainActor
    func testManualOpeningMeasurementsRetainSeparatePositionsAndSurviveRestart() {
        let app = launch()
        let name = createProject(in: app)
        app.tabBars.buttons["Съёмка"].tap()
        scrollAndTap("tools.measurements", in: app)
        for (index, value) in ["0.91", "0.93"].enumerated() {
            scrollAndTap("measurement.manual", in: app)
            enter("Контроль проёма \(index + 1)", identifier: "measurement.editor.label", in: app)
            tap("measurement.editor.role", in: app)
            app.buttons["W · ширина"].firstMatch.tap()
            tap("measurement.editor.target", in: app)
            app.buttons["Дверной проём"].firstMatch.tap()
            tap("measurement.editor.definition", in: app)
            app.buttons["Световой проход"].firstMatch.tap()
            tap("measurement.editor.position", in: app)
            app.buttons[index == 0 ? "Снизу" : "Сверху"].firstMatch.tap()
            enter(value, identifier: "measurement.editor.meters", in: app)
            if index == 1 { screenshot("27-opening-measurement", app: app) }
            tap("measurement.editor.save", in: app)
            waitForAbsence(element("measurement.editor.save", in: app))
        }
        scrollAndTap("measurement.mode.journal", in: app, towardTop: true)
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurement.record."))
        XCTAssertEqual(records.count, 2, "Both source observations must remain separate")
        XCTAssertTrue(records.element(boundBy: 0).label.contains("Контроль проёма"))
        screenshot("28-measurement-journal", app: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15))
        app.tabBars.buttons["Съёмка"].tap()
        scrollAndTap("tools.measurements", in: app)
        scrollAndTap("measurement.mode.journal", in: app, towardTop: true)
        XCTAssertEqual(records.count, 2, "The persisted observations disappeared after restart")
        records.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Карточка обмера"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("measurement.record.definition", in: app).label.contains("Световой проход"))
        XCTAssertTrue(element("measurement.record.target", in: app).label.contains("Дверной проём"))
    }

    @MainActor
    func testSurfaceClassificationAndManualCabinetDoorPersistWithoutChangingTheSource() {
        let app = launch(seedReview: true)
        let name = createProject(in: app)
        tap("projects.openSelected", in: app)
        tap("project.testSurfaceReview", in: app)
        XCTAssertTrue(app.navigationBars["Поверхности и проёмы"].waitForExistence(timeout: 10))
        for (suffix, symbol) in [("101", "D"), ("102", "W"), ("103", "P")] {
            let row = element("emptyRoom.surface.C0610000-1234-4000-8000-000000000" + suffix, in: app)
            scrollToControl(row, in: app)
            XCTAssertTrue(row.label.hasPrefix(symbol + " ·"), "The real catalog must keep distinct source classifications")
            XCTAssertTrue(row.label.contains("Не проверено"), "A synthetic source must not imply operator confirmation")
        }
        scrollToControl(element("emptyRoom.surface.C0610000-1234-4000-8000-000000000101", in: app), in: app, towardTop: true)
        screenshot("29-surface-classification", app: app)
        scrollAndTap("emptyRoom.addManualTarget", in: app)
        enter("Шкаф · дверца 1", identifier: "emptyRoom.review.label", in: app)
        let verified = app.switches["emptyRoom.review.verified"]
        scrollToControl(verified, in: app)
        XCTAssertEqual(verified.value as? String, "0")
        confirmSwitch("emptyRoom.review.verified", in: app)
        enter("Дверца осмотрена специалистом; габарит шкафа не использован как её размер.", identifier: "emptyRoom.review.note", in: app)
        tap("emptyRoom.review.save", in: app)
        waitForAbsence(element("emptyRoom.review.save", in: app))
        waitForAbsence(app.navigationBars["Проверить поверхность"])
        let manual = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "emptyRoom.manualTarget.")).firstMatch
        scrollToControl(manual, in: app)
        XCTAssertTrue(manual.label.hasPrefix("K · Шкаф · дверца 1"))
        screenshot("30-cabinet-door-review", app: app)
        let doorID = "C0610000-1234-4000-8000-000000000101"
        scrollAndTap("emptyRoom.measure." + doorID, in: app, towardTop: true)
        scrollAndTap("measurement.manual", in: app)
        enter("Контроль двери по рулетке", identifier: "measurement.editor.label", in: app)
        enter("0.88", identifier: "measurement.editor.meters", in: app)
        tap("measurement.editor.save", in: app)
        waitForAbsence(element("measurement.editor.save", in: app))
        app.navigationBars["Инструменты обмера"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Поверхности и проёмы"].waitForExistence(timeout: 10))
        scrollAndTap("emptyRoom.surface." + doorID, in: app, towardTop: true)
        XCTAssertTrue(element("emptyRoom.source.classification", in: app).label.contains("Дверь"))
        confirmSwitch("emptyRoom.review.verified", in: app)
        revealWholeControl(element("emptyRoom.review.meaning", in: app), in: app)
        tap("emptyRoom.review.meaning", in: app)
        app.buttons["Чистый проём · контрольный обмер"].firstMatch.tap()
        revealWholeControl(element("emptyRoom.review.measurement", in: app), in: app)
        tap("emptyRoom.review.measurement", in: app)
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Контроль двери по рулетке")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "A genuine measurement of this exact surface must be available for attachment")
        choice.tap()
        enter("Тип двери проверен; световая ширина измерена контрольной рулеткой.", identifier: "emptyRoom.review.note", in: app)
        tap("emptyRoom.review.save", in: app)
        waitForAbsence(element("emptyRoom.review.save", in: app))
        waitForAbsence(app.navigationBars["Проверить поверхность"])
        let door = element("emptyRoom.surface." + doorID, in: app)
        scrollToControl(door, in: app, towardTop: true)
        XCTAssertTrue(door.label.replacingOccurrences(of: ",", with: ".").contains("0.880"), "The attached control must appear on its exact source surface")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        tap("project.testSurfaceReview", in: app)
        XCTAssertTrue(app.navigationBars["Поверхности и проёмы"].waitForExistence(timeout: 10))
        scrollToControl(manual, in: app)
        XCTAssertTrue(manual.label.hasPrefix("K · Шкаф · дверца 1"), "The operator classification journal must survive process restart")
        scrollToControl(element("emptyRoom.surface.C0610000-1234-4000-8000-000000000101", in: app), in: app, towardTop: true)
        XCTAssertTrue(element("emptyRoom.surface.C0610000-1234-4000-8000-000000000101", in: app).label.hasPrefix("D ·"),
                      "A manual cabinet door must not overwrite the original room-door classification")
        XCTAssertTrue(door.label.replacingOccurrences(of: ",", with: ".").contains("0.880"), "The attached control journal must persist across restart")
    }

    @MainActor
    func testTeamPlanCreatesFiveRealAssignmentsAndPersistsTheExplicitWorkerSelection() {
        let app = launch(seedCemetery: true)
        XCTAssertTrue(app.staticTexts["Демо · полевое обследование"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        revealWholeControl(element("projects.collaborativeSurvey", in: app), in: app)
        tap("projects.collaborativeSurvey", in: app)
        XCTAssertTrue(element("collaboration.create", in: app).waitForExistence(timeout: 15))
        tap("collaboration.create", in: app)
        let boundary = element("collaboration.setup.boundary", in: app)
        revealWholeControl(boundary, in: app)
        boundary.tap()
        let boundaryChoice = app.buttons["Учебное кладбище"].firstMatch
        XCTAssertTrue(boundaryChoice.waitForExistence(timeout: 10), "The original geographic polygon must be selectable")
        boundaryChoice.tap()
        let count = element("collaboration.setup.count", in: app)
        XCTAssertTrue(count.label.contains("5"), "The tested plan must actually contain five workers")
        enter("Специалист QA", identifier: "collaboration.setup.name.0", in: app)
        enter("20", identifier: "collaboration.setup.cellSize", in: app)
        revealWholeControl(element("collaboration.setup.preview", in: app), in: app)
        tap("collaboration.setup.preview", in: app)
        XCTAssertTrue(app.navigationBars["Проверка участков"].waitForExistence(timeout: 30),
                      "Planning must finish on the actual boundary and show a review before saving")
        XCTAssertTrue(element("collaboration.canvas", in: app).exists)
        let panMode = element("collaboration.panMode", in: app)
        XCTAssertTrue(panMode.waitForExistence(timeout: 10), "The map must expose its real interaction mode")
        XCTAssertEqual(panMode.value as? String, "Выключен",
                       "Review must allow normal page scrolling until diagram panning is explicitly enabled")
        screenshot("33-team-planning", app: app)
        revealWholeControl(element("collaboration.confirmPlan", in: app), in: app)
        tap("collaboration.confirmPlan", in: app)
        XCTAssertTrue(element("collaboration.summary", in: app).waitForExistence(timeout: 20))
        let worker = element("collaboration.worker", in: app)
        revealWholeControl(worker, in: app)
        revealWholeControl(element("collaboration.guidance.start", in: app), in: app)
        XCTAssertTrue(element("collaboration.guidance.start", in: app).exists)
        XCTAssertFalse(element("collaboration.guidance.start", in: app).isEnabled,
                       "A new phone must explicitly choose a worker before GPS guidance")
        revealWholeControl(worker, in: app, towardTopWhenMissing: true)
        worker.tap()
        let chosenWorker = app.buttons["Специалист QA"].firstMatch
        XCTAssertTrue(chosenWorker.waitForExistence(timeout: 10)); chosenWorker.tap()
        revealWholeControl(element("collaboration.guidance.start", in: app), in: app)
        XCTAssertTrue(element("collaboration.guidance.start", in: app).isEnabled,
                      "The chosen worker must affect the real plan, without starting sensors automatically")
        revealWholeControl(element("collaboration.cells", in: app), in: app, towardTopWhenMissing: true)
        tap("collaboration.cells", in: app)
        let firstCell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collaboration.cell.r")).firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 10), "The selected worker must own actual planned cells")
        let selectedCellIdentifier = firstCell.identifier
        firstCell.tap()
        XCTAssertTrue(element("collaboration.cell.owner", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("collaboration.cell.owner", in: app).label, "Назначено: Специалист QA")
        screenshot("34-team-coverage", app: app)
        let coverage = element("collaboration.cell.coverage", in: app)
        XCTAssertTrue(coverage.waitForExistence(timeout: 10), "The actual cell coverage state must be accessible")
        XCTAssertEqual(coverage.label, "Состояние покрытия ячейки")
        XCTAssertEqual(coverage.value as? String, "Без материалов",
                       "Planning alone must keep the real Core.unobserved state without manufacturing capture coverage")
        revealWholeControl(element("collaboration.cell.attach", in: app), in: app)
        XCTAssertFalse(element("collaboration.cell.attach", in: app).isEnabled,
                       "A cell cannot claim a capture without a real project source file")
        revealWholeControl(element("collaboration.cell.verify", in: app), in: app)
        XCTAssertFalse(element("collaboration.cell.verify", in: app).isEnabled,
                       "A cell cannot be verified without reviewed usable capture evidence")
        revealWholeControl(element("collaboration.cell.walk", in: app), in: app)
        XCTAssertFalse(element("collaboration.cell.walk", in: app).isEnabled,
                       "Opening a cell must not invent a fresh GPS observation")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Демо · полевое обследование"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        revealWholeControl(element("projects.collaborativeSurvey", in: app), in: app)
        tap("projects.collaborativeSurvey", in: app)
        XCTAssertTrue(element("collaboration.summary", in: app).waitForExistence(timeout: 20),
                      "The same durable shared plan must survive process restart")
        revealWholeControl(element("collaboration.worker", in: app), in: app)
        let restoredWorker = element("collaboration.worker", in: app)
        XCTAssertTrue(restoredWorker.label.contains("Специалист QA") || (restoredWorker.value as? String)?.contains("Специалист QA") == true,
                      "The explicit worker identity must remain device-local and persist")
        revealWholeControl(element("collaboration.cells", in: app), in: app, towardTopWhenMissing: true)
        tap("collaboration.cells", in: app)
        XCTAssertTrue(element(selectedCellIdentifier, in: app).waitForExistence(timeout: 10),
                      "Planning must restore the same cell identifiers and allocation")
    }

    @MainActor
    func testFragmentAssemblyRequiresActualScansAndTeamImportUsesTheNativeChooser() {
        let app = launch()
        let name = createProject(in: app)
        tap("projects.openSelected", in: app)
        revealWholeControl(element("projects.fragmentAssembly", in: app), in: app)
        tap("projects.fragmentAssembly", in: app)
        XCTAssertTrue(element("assembly.emptyState", in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(element("assembly.exportAligned", in: app).exists,
                       "An empty project must never offer a made-up assembled mesh")
        revealWholeControl(element("assembly.guide", in: app), in: app)
        XCTAssertTrue(element("assembly.guide", in: app).label.contains("не менее трёх"),
                      "The workflow must explain independent controls and a separate check point")
        screenshot("35-fragment-assembly", app: app)
        let back = app.navigationBars["Сборка фрагментов"].buttons.firstMatch
        XCTAssertTrue(back.isHittable); back.tap()
        XCTAssertTrue(app.navigationBars[name].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars[name].buttons.firstMatch.tap()
        tap("projects.importTeamPlan", in: app)
        XCTAssertTrue(app.navigationBars["План команды"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("teamPlan.chooseFile", in: app).isEnabled)
        XCTAssertFalse(element("teamPlan.acceptImport", in: app).exists,
                       "Import must not activate a project before a valid file is selected and checked")
        screenshot("36-team-import", app: app)
        tap("teamPlan.chooseFile", in: app)
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Отменить", "Отмена"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "The real native Files chooser must open")
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(element("teamPlan.chooseFile", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("teamPlan.acceptImport", in: app).exists,
                       "Cancelling file selection must leave the import uncommitted")
        app.navigationBars["План команды"].buttons["Закрыть"].tap()
        XCTAssertTrue(element("projects.openSelected", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists, "Cancelled import must retain the selected original project")
    }

    @MainActor
    func testLaunchResponsivenessMetric() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "--uitest-local-fixtures"]
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            XCTAssertTrue(element("projects.create", in: app).waitForExistence(timeout: 15),
                          "Launch must reach the usable project screen")
            app.terminate()
        }
    }
}
