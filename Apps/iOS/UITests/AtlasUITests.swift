import Foundation
import CoreGraphics
import UIKit
import XCTest

/// These tests execute the native app in Simulator. They verify navigation,
/// persisted projects, explicit hardware fallback, and the real SceneKit viewer.
/// Simulator cannot validate camera frames, LiDAR geometry, or measurement accuracy.
final class AtlasUITests: XCTestCase {
    @MainActor
    private func launch(seedMesh: Bool = false, seedCemetery: Bool = false, seedBuilding: Bool = false, seedTour: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        if seedMesh { app.launchArguments.append("--uitest-seed-mesh") }
        if seedCemetery { app.launchArguments.append("--uitest-seed-cemetery") }
        if seedBuilding { app.launchArguments.append("--uitest-seed-building") }
        if seedTour { app.launchArguments.append("--uitest-seed-tour") }
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
        scrollAndTap("projects.cemetery", in: app)
        XCTAssertTrue(app.staticTexts["Учебное кладбище"].firstMatch.waitForExistence(timeout: 15),
                      "Fieldwork must load the actual saved cemetery rather than an empty demonstration screen")
        tap("cemetery.map", in: app)
        XCTAssertTrue(element("map.layers", in: app).waitForExistence(timeout: 15))
    }

    @MainActor
    private func openMapCard(_ suffix: String, in app: XCUIApplication) {
        let identifier = "map.card.A71A5000-1234-4000-8000-000000000" + suffix
        let card = element(identifier, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The saved map card is missing: \(identifier)")
        for _ in 0..<4 {
            if card.isHittable {
                card.tap()
                XCTAssertTrue(element("burial.status.summary", in: app).waitForExistence(timeout: 15),
                              "The saved grave must open its real burial card")
                return
            }
            let strip = app.scrollViews.containing(.button, identifier: identifier).firstMatch
            XCTAssertTrue(strip.exists, "The map card must belong to the real object strip")
            strip.swipeLeft()
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
        graveLayer.tap()
        XCTAssertEqual(graveLayer.value as? String, "0")
        screenshot("20-map-layers", app: app)
        app.navigationBars["Слои карты"].buttons["Готово"].tap()
        waitForAbsence(grave)

        tap("map.layers", in: app)
        let restoredLayer = app.switches["map.layer.grave"]
        scrollToControl(restoredLayer, in: app)
        restoredLayer.tap()
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
        let notesField = element("burial.notes", in: app)
        scrollToControl(notesField, in: app)
        notesField.tap(); notesField.typeText(comment)
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

        scrollAndTap("burial.history", in: app)
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
        inactive.tap()
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
        restoredInactive.tap()
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
        let secondPlan = element("building.plan.A71A5000-1234-4000-8000-000000000204", in: app)
        scrollToControl(secondPlan, in: app)
        XCTAssertTrue(element("building.floor.2", in: app).exists,
                      "A saved floorIndex must produce its actual floor group")
        let firstPlan = element("building.plan.A71A5000-1234-4000-8000-000000000203", in: app)
        scrollToControl(firstPlan, in: app)
        XCTAssertTrue(element("building.floor.1", in: app).exists)
        XCTAssertTrue(app.staticTexts["Учебный обмер · этаж 1"].exists)
        screenshot("22-building-plans", app: app)
        firstPlan.tap()
        XCTAssertTrue(app.staticTexts["Учебный обмер · этаж 1"].firstMatch.waitForExistence(timeout: 15),
                      "Opening a catalog plan must select that exact saved plan, not an arbitrary floor")
        let dimensions = app.switches["floorPlan.dimensions"]
        scrollToControl(dimensions, in: app)
        XCTAssertEqual(dimensions.value as? String, "1")
        let drawing = element("floorPlan.drawing", in: app)
        XCTAssertTrue(drawing.waitForExistence(timeout: 10))
        XCTAssertTrue(drawing.label.contains("1 комнат") && drawing.label.contains("4 стен"),
                      "The viewport must receive the actual persisted room and walls")
        guard let withDimensions = drawingPixels(drawing.screenshot().image) else {
            XCTFail("The real floor-plan viewport did not produce a readable image")
            return
        }
        dimensions.tap()
        XCTAssertEqual(dimensions.value as? String, "0")
        guard let withoutDimensions = drawingPixels(drawing.screenshot().image) else {
            XCTFail("The floor-plan viewport disappeared after hiding dimensions")
            return
        }
        XCTAssertGreaterThan(changedDrawingPixels(withDimensions, withoutDimensions), 20,
                             "Hiding dimensions must change the native drawing itself, not just the switch")
        dimensions.tap()
        XCTAssertEqual(dimensions.value as? String, "1")
        screenshot("22b-plan-dimensions", app: app)
        scrollToControl(app.staticTexts["Учебная комната"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Учебная комната"].exists,
                      "The room must still exist after the presentation-only dimension changes")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Демо · этажи здания"].firstMatch.waitForExistence(timeout: 15))
        tap("projects.openSelected", in: app)
        scrollAndTap("projects.buildingPlans", in: app)
        scrollToControl(element("building.plan.A71A5000-1234-4000-8000-000000000203", in: app), in: app)
        XCTAssertTrue(element("building.floor.1", in: app).exists,
                      "Floor grouping must survive restarting the process")
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
            if waitForLabel(result, containing: "Первая точка", timeout: 1) {
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
        let numeric = label.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
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
    func testLaunchResponsivenessMetric() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
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
