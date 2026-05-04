//  Tests TDD para Localizable.xcstrings.
//  Verifica que el catálogo está presente con traducciones ES+EN
//  para las claves UI críticas.

import Foundation
@testable import NodeClientCore
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func test_localizable_catalog_filePresent_andValidJSON() throws {
        let url = Self.repoRoot.appendingPathComponent("NodeClient/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try XCTUnwrap(parsed as? [String: Any])
        XCTAssertEqual(
            dict["sourceLanguage"] as? String,
            "es",
            "Source language debe ser español (key=ES por convención)"
        )
        XCTAssertEqual(
            dict["version"] as? String,
            "1.0",
            "Version 1.0 del formato String Catalog"
        )
    }

    func test_localizable_catalog_includesEnglishTranslations_forCriticalKeys() throws {
        let strings = try loadStringsDictionary()

        // Subset crítico: keys que aparecen en flows del usuario.
        // removidas Papelera/Restaurar/Vaciar; +confirm dialog delete.
        // +keys de Register / Rename / Move (full API parity).
        let criticalKeys = [
            "Cancelar",
            "Cerrar",
            "Confirmar",
            "Recientes",
            "Favoritos",
            "Fotos",
            "Sin conexión",
            "Eliminar",
            "¿Eliminar archivo?",
            "Esta acción no se puede deshacer. El archivo se borrará permanentemente.",
            "Crear cuenta",
            "Código de invitación",
            "Confirmar contraseña",
            "¿No tienes cuenta?",
            "Renombrar",
            "Mover",
            "Nuevo nombre"
        ]

        for key in criticalKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Falta key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let en = try XCTUnwrap(
                localizations["en"] as? [String: Any],
                "Key '\(key)' falta traducción EN"
            )
            let stringUnit = try XCTUnwrap(en["stringUnit"] as? [String: Any])
            let value = try XCTUnwrap(stringUnit["value"] as? String)
            XCTAssertFalse(
                value.isEmpty,
                "Key '\(key)' tiene EN translation vacía"
            )
            XCTAssertNotEqual(
                value,
                key,
                "Key '\(key)' EN translation debe diferir del ES (key=ES por convención)"
            )
        }
    }

    func test_localizable_catalog_state_translated_forAllEnglishEntries() throws {
        let strings = try loadStringsDictionary()
        var keysWithMissingTranslation: [String] = []

        // Estados válidos: `translated` (traducción confirmada por el
        // traductor) y `needs_review` (Xcode lo marca cuando el valor
        // difiere del key — aceptable cuando el catálogo tiene
        // sourceLanguage `es` y el key parece inglés, ej. "Base URL"
        // cuyo es value es "URL"). Estados problemáticos a detectar:
        // `new` (nunca tocado por humano) o ausente.
        let acceptedStates: Set<String> = ["translated", "needs_review"]

        for (key, entry) in strings {
            guard let entryDict = entry as? [String: Any],
                  let localizations = entryDict["localizations"] as? [String: Any],
                  let en = localizations["en"] as? [String: Any],
                  let stringUnit = en["stringUnit"] as? [String: Any]
            else {
                continue
            }
            let state = stringUnit["state"] as? String ?? ""
            if !acceptedStates.contains(state) {
                keysWithMissingTranslation.append(key)
            }
        }

        XCTAssertTrue(
            keysWithMissingTranslation.isEmpty,
            "Estas keys tienen state inaceptable (esperado 'translated' o 'needs_review'): \(keysWithMissingTranslation)"
        )
    }

    private func loadStringsDictionary() throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent("NodeClient/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try XCTUnwrap(parsed as? [String: Any])
        return try XCTUnwrap(dict["strings"] as? [String: Any])
    }
}
