//  EncryptionKeyVault.
//
//  Singleton observable que mantiene la `SymmetricKey` activa derivada
//  por `EncryptionPasswordCoordinator.unlock` para que cualquier vista
//  del cliente (FilesViewModel, MoreViewModel, etc.) pueda detectar
//  si la sesión de cifrado está abierta y usar la key sin reverificar
//  la contraseña.
//
//  Lifecycle:
//  - `EncryptionSettingsViewModel.unlock(...)` o `configurePassword(...)`
//    publican la key vía `unlock(key:forUsername:)`.
//  - `EncryptionSettingsViewModel.lock()` o `resetEncryption()` la borran.
//  - `SessionStore.logout()` debe limpiar el vault para impedir que un
//    usuario que cierre sesión deje su key disponible al siguiente login.
//
//  La key NUNCA persiste en disco; sólo en memoria mientras
//  el proceso esté vivo. El vault respeta esa invariante.

import Combine
import CryptoKit
import Foundation

@MainActor
final class EncryptionKeyVault: ObservableObject {
    /// Singleton para el flow del app. Tests inyectan instancias propias.
    static let shared = EncryptionKeyVault()

    /// Key derivada y guardada en RAM. Nil = sesión de cifrado bloqueada
    /// o no configurada.
    @Published private(set) var currentKey: SymmetricKey?
    /// Username asociado a la key. Si la sesión cambia, la key se
    /// invalida para evitar que un usuario reuse la key de otro.
    @Published private(set) var currentUsername: String?

    init() {}

    /// Publica una key activa. Llamar tras setup o unlock exitoso.
    func unlock(key: SymmetricKey, forUsername username: String) {
        currentKey = key
        currentUsername = username
    }

    /// Limpia la key y el username. Llamar al lock manual, reset, o logout
    /// de sesión.
    func lock() {
        currentKey = nil
        currentUsername = nil
    }

    /// True si hay key activa.
    var isUnlocked: Bool { currentKey != nil }
}
