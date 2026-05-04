//  Tipos extraídos de `FilesViewModel.swift` para mantener el archivo
//  principal por debajo del cap de SwiftLint (`file_length: 1300`).
//
//  - `PendingOverwrite`: propuesta pendiente que la View consume para
//    confirmar la sobreescritura de un path ya asignado.
//  - `ProjectionSignature`: signature equatable que usa el VM para
//    decidir si recomputar la proyección visible.

import Foundation

/// Propuesta pendiente de sobreescritura cuando un upload colisiona con
/// un path ya asignado a un entry vivo. La View la usa para mostrar un
/// confirmation dialog antes de reusar el entryId canónico existente.
struct PendingOverwrite: Identifiable {
    let id = UUID()
    let existingEntryId: String
    let path: String
    let fileName: String
    /// Wire ya preparado (cifrado streaming a temp si aplica + checksum).
    let prepared: PreparedUpload
    let plaintextSize: Int64
    let isEncrypted: Bool
}

struct ProjectionSignature: Equatable {
    let fileIDs: [String]
    let query: String
    let sortMode: FilesSortMode
    let folderPath: String
}
