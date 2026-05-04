//  Tests TDD para validar configuración App Store
//  readiness: ATS strict + dev exception, PrivacyInfo presente,
//  entitlements consolidados.

import Foundation
@testable import NodeClientCore
import XCTest

final class AppStoreReadinessTests: XCTestCase {
    // MARK: - Resolver paths

    /// Resolves repo root suiendo el filePath del propio test.
    /// Necesario porque SwiftPM no expone el repo root via API.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NodeClientCoreTests/
            .deletingLastPathComponent() // NodeClient/
    }

    // MARK: - ATS configuration (Fase 2)

    func test_ats_infoPlist_disablesArbitraryLoads() throws {
        let infoPlist = try loadAppInfoPlist()
        let ats = try XCTUnwrap(
            infoPlist["NSAppTransportSecurity"] as? [String: Any],
            "NSAppTransportSecurity debe estar presente en NodeClient-Info.plist"
        )
        let allowsArbitrary = try XCTUnwrap(
            ats["NSAllowsArbitraryLoads"] as? Bool,
            "NSAllowsArbitraryLoads debe declararse explícitamente"
        )
        XCTAssertFalse(
            allowsArbitrary,
            "ATS strict en release; HTTPS por defecto"
        )
    }

    func test_ats_infoPlist_allowsLocalhostHTTP() throws {
        let infoPlist = try loadAppInfoPlist()
        let ats = try XCTUnwrap(infoPlist["NSAppTransportSecurity"] as? [String: Any])
        let exceptions = try XCTUnwrap(
            ats["NSExceptionDomains"] as? [String: Any],
            "NSExceptionDomains debe contener exception para localhost"
        )

        let localhost = try XCTUnwrap(
            exceptions["localhost"] as? [String: Any],
            "localhost debe permitir HTTP en desarrollo"
        )
        XCTAssertEqual(
            localhost["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true
        )

        let loopback = try XCTUnwrap(
            exceptions["127.0.0.1"] as? [String: Any],
            "127.0.0.1 también debe permitir HTTP en desarrollo"
        )
        XCTAssertEqual(
            loopback["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true
        )
    }

    func test_ats_infoPlist_doesNotIncludeArbitraryProductionDomain() throws {
        let infoPlist = try loadAppInfoPlist()
        let ats = try XCTUnwrap(infoPlist["NSAppTransportSecurity"] as? [String: Any])
        let exceptions = (ats["NSExceptionDomains"] as? [String: Any]) ?? [:]

        // Verificación contra drift: solo localhost + 127.0.0.1.
        let allowedDomains: Set<String> = ["localhost", "127.0.0.1"]
        let actualDomains = Set(exceptions.keys)
        XCTAssertEqual(
            actualDomains,
            allowedDomains,
            "Cambios en NSExceptionDomains requieren update"
        )
    }

    // MARK: - PrivacyInfo

    func test_privacyInfo_filePresent_andValidPlist() throws {
        let plist = try loadPrivacyInfo()
        XCTAssertNotNil(
            plist["NSPrivacyAccessedAPITypes"],
            "PrivacyInfo.xcprivacy debe declarar NSPrivacyAccessedAPITypes"
        )
    }

    func test_privacyInfo_disablesTrackingExplicitly() throws {
        let plist = try loadPrivacyInfo()
        let tracking = try XCTUnwrap(plist["NSPrivacyTracking"] as? Bool)
        XCTAssertFalse(
            tracking,
            "NodeClient NO realiza tracking; modelo enterprise-cerrado"
        )

        let trackingDomains = try XCTUnwrap(plist["NSPrivacyTrackingDomains"] as? [String])
        XCTAssertTrue(trackingDomains.isEmpty, "Cero dominios tracking declarados")

        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [Any])
        XCTAssertTrue(collected.isEmpty, "Cero data collection hacia terceros")
    }

    func test_privacyInfo_declaresRequiredReasonAPIs() throws {
        let plist = try loadPrivacyInfo()
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])

        let categories = apis.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertTrue(
            categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"),
            "UserDefaults uses present (SessionStore, telemetry, prefs)"
        )
        XCTAssertTrue(
            categories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"),
            "FileTimestamp uses present (sync metadata)"
        )
    }

    // MARK: - Entitlements review

    func test_appEntitlements_includeAppGroupAndKeychainSharing() throws {
        let plist = try loadEntitlements(at: "NodeClient/NodeClient.entitlements")

        let appGroups = try XCTUnwrap(
            plist["com.apple.security.application-groups"] as? [String],
            "App Group entitlement requerido para shared state"
        )
        XCTAssertEqual(appGroups, ["group.es.ual.NodeClient"])

        let keychainGroups = try XCTUnwrap(
            plist["keychain-access-groups"] as? [String],
            "Keychain Sharing requerido para token compartido"
        )
        XCTAssertTrue(
            keychainGroups.contains("$(AppIdentifierPrefix)es.ual.NodeClient"),
            "Keychain access group debe coincidir con team prefix bundle"
        )
    }

    // MARK: - Helpers

    private func loadAppInfoPlist() throws -> [String: Any] {
        try loadPlist(at: "NodeClient/NodeClient-Info.plist")
    }

    private func loadPrivacyInfo() throws -> [String: Any] {
        try loadPlist(at: "NodeClient/PrivacyInfo.xcprivacy")
    }

    private func loadEntitlements(at relativePath: String) throws -> [String: Any] {
        try loadPlist(at: relativePath)
    }

    private func loadPlist(at relativePath: String) throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(plist as? [String: Any])
    }
}
