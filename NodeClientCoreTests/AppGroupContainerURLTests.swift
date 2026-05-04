//  Tests TDD para NodeClientAppGroups.containerURL +
//  resolución del directorio base de los stores SQLite.

import Foundation
@testable import NodeClientCore
import XCTest

final class AppGroupContainerURLTests: XCTestCase {
    func test_containerURL_returnsNil_whenFileManagerHasNoStub() {
        // Mockeamos un FileManager que NO tiene entitlement App Group.
        // Verificamos que `containerURL` propaga el `nil` para activar
        // el fallback graceful. Sin mock, el resultado
        // depende de la firma del binario host (Xcode dev vs SwiftPM
        // sin firma) y no es determinista.
        let mockFileManager = StubAppGroupFileManager(stubbed: nil)
        let url = NodeClientAppGroups.containerURL(fileManager: mockFileManager)
        XCTAssertNil(url)
    }

    func test_containerURL_returnsConfiguredURL_whenFileManagerProvidesOne() {
        // Inyectamos un FileManager mock que sí "tiene" entitlement.
        let stubURL = URL(fileURLWithPath: "/tmp/fake-container/group.es.ual.NodeClient")
        let mockFileManager = StubAppGroupFileManager(stubbed: stubURL)

        let result = NodeClientAppGroups.containerURL(fileManager: mockFileManager)

        XCTAssertEqual(result, stubURL)
        XCTAssertEqual(mockFileManager.requestedGroups, ["group.es.ual.NodeClient"])
    }

    func test_resolvedDataDirectory_prefersAppGroup_whenContainerExists() {
        let stubURL = URL(fileURLWithPath: "/tmp/fake-container")
        let mockFileManager = StubAppGroupFileManager(stubbed: stubURL)

        let resolved = NodeClientAppGroups.resolvedDataDirectory(fileManager: mockFileManager)

        XCTAssertEqual(
            resolved.path,
            "/tmp/fake-container/NodeClient",
            "Cuando el App Group container existe, todos los stores deben usarlo"
        )
    }

    func test_resolvedDataDirectory_fallsBackToApplicationSupport_whenContainerMissing() {
        let mockFileManager = StubAppGroupFileManager(stubbed: nil)

        let resolved = NodeClientAppGroups.resolvedDataDirectory(fileManager: mockFileManager)

        XCTAssertTrue(
            resolved.path.contains("NodeClient"),
            "El fallback debe seguir bajo el subdirectorio NodeClient para coherencia"
        )
        XCTAssertFalse(
            resolved.path.contains("group.es.ual.NodeClient"),
            "El fallback no debe estar bajo Group Containers cuando el entitlement falta"
        )
    }
}

/// Doble que mockea `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
/// inyectable. Permite tests deterministas sin dependencias en
/// firma del binario.
private final class StubAppGroupFileManager: FileManager {
    private let stubbed: URL?
    private(set) var requestedGroups: [String] = []

    init(stubbed: URL?) {
        self.stubbed = stubbed
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        requestedGroups.append(groupIdentifier)
        return stubbed
    }
}
