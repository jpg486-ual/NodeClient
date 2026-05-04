//  AccessibilityAudit XCTest (Xcode 15+).
//
//  Estos tests requieren un UI Tests target con host
//  application iOS Simulator. Para ejecutar:
//
//      xcodebuild test \
//          -project NodeClient.xcodeproj \
//          -scheme NodeClientUITests \
//          -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
//
//  El target NodeClientUITests no está añadido al pbxproj
//
//  Hasta entonces, este archivo sirve como template + documentación
//  del audit que se ejecutará cuando el target esté activo.

import XCTest

final class AccessibilityAuditTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        // Variante de launch arguments para que la app entre en modo
        // demo (sin red) y así el audit no dependa del backend Node:
        app.launchArguments += ["-NCRunMode", "demo"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    func test_loginScreen_passesAccessibilityAudit() throws {
        // El estado inicial post-launch suele ser LoginView. El audit
        // verifica labels, hit targets, contrast, dynamic type.
        XCTAssertTrue(app.textFields["Base URL"].exists, "LoginView debe estar visible")
        try app.performAccessibilityAudit()
    }

    func test_filesScreen_passesAccessibilityAudit() throws {
        // Login con credenciales demo + esperar a que cargue la lista.
        let baseURL = app.textFields["Base URL"]
        baseURL.tap()
        baseURL.typeText("http://localhost:8081")

        let username = app.textFields["Username"]
        username.tap()
        username.typeText("demo")

        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("demo")

        app.buttons["Sign In"].tap()

        // Esperar a que aparezca la pantalla Files.
        XCTAssertTrue(
            app.navigationBars["File"].waitForExistence(timeout: 5),
            "FilesView debe cargar tras login demo"
        )

        try app.performAccessibilityAudit()
    }
}
