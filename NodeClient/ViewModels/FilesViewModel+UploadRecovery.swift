//  Helpers de auto-recovery 409 silencioso para `performUpload`.
//
//  Extraídos en una extension para mantener `FilesViewModel.swift` por
//  debajo del `file_length` warning de SwiftLint sin perder cohesión:
//  el handler del catch en `performUpload` consulta `Self.uploadConflictRecovery(for:)`
//  para clasificar el código de error 409 y delega el refetch silencioso
//  en `silentRefreshTree`.

import Foundation

extension FilesViewModel {
    /// Tipo de recuperación posible ante un 409 durante el upload. Los
    /// callers (catch de `performUpload`) actúan diferente según el caso:
    ///  - `.retrySameOperation`: refetch + reintento del mismo upsert /
    ///    upload-session.
    ///  - `.resolvePathCollision`: refetch + decisión por estado del
    ///    entry recién traído (silent overwrite si `deleted=true`,
    ///    diálogo `PendingOverwrite` si está vivo).
    enum UploadConflictRecovery {
        case retrySameOperation
        case resolvePathCollision
    }

    /// Mapea el `errorCode` recibido del backend a la estrategia de
    /// recuperación. `nil` si el código no corresponde a un 409
    /// recuperable (el caller cae al toast normal).
    static func uploadConflictRecovery(for errorCode: String) -> UploadConflictRecovery? {
        switch errorCode {
        case "FILE_UPLOAD_CHUNK_CONFLICT",
             "FILE_UPLOAD_COMPLETE_CONFLICT",
             "FILE_CONTENT_CONFLICT":
            return .retrySameOperation

        case "FS_PATH_CONFLICT":
            return .resolvePathCollision

        default:
            return nil
        }
    }
}
