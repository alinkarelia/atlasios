import Foundation
import CoreGraphics
import UIKit
import XCTest

/// These tests execute the native app in Simulator. They verify navigation,
/// persisted projects, explicit hardware fallback, and the real SceneKit viewer.
/// Simulator cannot validate camera frames, LiDAR geometry, or measurement accuracy.
final class AtlasUITests: XCTestCase {
    @MainActor
    private func launch(seedMesh: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        if seedMesh { app.launchArguments.append("--uitest-seed-mesh") }
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
