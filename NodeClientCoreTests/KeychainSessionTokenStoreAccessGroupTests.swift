//  Tests TDD del refactor `KeychainSessionTokenStore`
//  para soportar `accessGroup`. El access group se mantiene firmado
//  como infraestructura preparada para las mejoras futuras. 
//  Estos tests preservan la regresión sobre el access group.

import Foundation
@testable import NodeClientCore
import XCTest

final class KeychainSessionTokenStoreAccessGroupTests: XCTestCase {
    func test_keychainStore_defaultInit_isRetrocompatible() {
        // El ctor existente sin parámetros sigue funcionando
        let store = KeychainSessionTokenStore()
        XCTAssertNil(store.testHookAccessGroup,
                     "ctor default no comparte el keychain con ninguna extensión")
    }

    func test_keychainStore_explicitAccessGroup_isExposed() {
        let store = KeychainSessionTokenStore(accessGroup: "NZT7MS65HC.es.ual.NodeClient")
        XCTAssertEqual(store.testHookAccessGroup, "NZT7MS65HC.es.ual.NodeClient")
    }

    func test_keychainStore_baseQuery_doesNotIncludeAccessGroup_whenNotProvided() {
        let store = KeychainSessionTokenStore()
        let query = store.testHookBaseQuery

        XCTAssertNil(query[kSecAttrAccessGroup as String],
                     "sin accessGroup explícito, Apple usa el default del bundle (no compartido)")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "es.ual.nodeclient")
    }

    func test_keychainStore_baseQuery_includesAccessGroup_whenProvided() {
        let store = KeychainSessionTokenStore(accessGroup: "NZT7MS65HC.es.ual.NodeClient")
        let query = store.testHookBaseQuery

        XCTAssertEqual(
            query[kSecAttrAccessGroup as String] as? String,
            "NZT7MS65HC.es.ual.NodeClient",
            "kSecAttrAccessGroup permite que la extensión lea items escritos por la app"
        )
    }
}
