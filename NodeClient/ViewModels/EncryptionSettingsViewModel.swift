//  Token-based encryption settings.
//
//  Estados:
//    .notConfigured             → primera vez, sin verifier en Keychain.
//    .lockedAwaitingPassword    → verifier persistido pero token local
//                                  ausente (usuario rechazó "Guardar en
//                                  este dispositivo"); requiere importar
//                                  archivo para reactivar.
//    .unlocked(since:)          → key activa en memoria.
//
//  El usuario nunca teclea contraseña: o genera un token de 256 bits o
//  importa uno previamente generado.

import Combine
import CryptoKit
import Foundation

@MainActor
final class EncryptionSettingsViewModel: ObservableObject {
    enum State: Equatable {
        case notConfigured
        case lockedAwaitingPassword
        case unlocked(since: Date)
    }

    @Published private(set) var state: State = .notConfigured
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var infoMessage: String?

    /// Token recién generado en esta sesión, sólo no-nil entre la acción
    /// "Generar" y el cierre del sheet de presentación. Se usa para
    /// permitir export/copia inmediata. No se persiste fuera de Keychain.
    @Published private(set) var freshlyGeneratedBundle: EncryptionTokenBundle?

    /// Key derivada y cacheada en memoria mientras unlocked.
    private(set) var unlockedKey: SymmetricKey?

    private let coordinator: EncryptionPasswordCoordinator
    private let username: String
    private let clock: () -> Date
    private let keyVault: EncryptionKeyVault?

    init(
        coordinator: EncryptionPasswordCoordinator,
        username: String,
        clock: @escaping () -> Date = { Date() },
        keyVault: EncryptionKeyVault? = nil
    ) {
        self.coordinator = coordinator
        self.username = username
        self.clock = clock
        self.keyVault = keyVault
        refreshState()
    }

    /// Detecta el estado actual leyendo el store. Llamado al init y tras
    /// operaciones que cambian config. Si hay verifier + token, intenta
    /// auto-unlock silencioso para llegar directo a `.unlocked`.
    func refreshState() {
        do {
            guard try coordinator.store.readVerifier(forUsername: username) != nil else {
                state = .notConfigured
                return
            }
        } catch {
            state = .notConfigured
            return
        }

        if let key = try? coordinator.unlockFromStoredToken(forUsername: username) {
            unlockedKey = key
            keyVault?.unlock(key: key, forUsername: username)
            state = .unlocked(since: clock())
        } else {
            state = .lockedAwaitingPassword
        }
    }

    /// Genera un token nuevo, lo configura, opcionalmente lo persiste en
    /// Keychain. Tras éxito, deja `freshlyGeneratedBundle` no-nil para
    /// que la View muestre el sheet con el plain token + opción exportar.
    func generateToken(persistInDevice: Bool) async {
        errorMessage = nil
        infoMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try coordinator.generateAndConfigureToken(
                forUsername: username,
                persistToken: persistInDevice
            )
            unlockedKey = result.key
            keyVault?.unlock(key: result.key, forUsername: username)
            freshlyGeneratedBundle = EncryptionTokenBundle(token: result.generated)
            state = .unlocked(since: clock())
            infoMessage = persistInDevice
                ? "Token generado y guardado en este dispositivo."
                : "Token generado. No se ha guardado: necesitarás importarlo de nuevo al reabrir la app."
        } catch EncryptionPasswordCoordinator.SetupError.alreadyConfigured {
            errorMessage = "Ya hay cifrado configurado. Resetea primero para generar uno nuevo."
        } catch {
            errorMessage = "No se pudo generar el token de cifrado."
        }
    }

    /// Importa un token desde un archivo previamente exportado en otro
    /// dispositivo. Tras éxito, deja el cifrado activo en este dispositivo.
    func importToken(from data: Data, persistInDevice: Bool) async {
        errorMessage = nil
        infoMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let bundle = try JSONDecoder().decode(EncryptionTokenBundle.self, from: data)
            let generated = try bundle.toGeneratedToken()
            let key = try coordinator.importToken(
                generated,
                forUsername: username,
                persistToken: persistInDevice
            )
            unlockedKey = key
            keyVault?.unlock(key: key, forUsername: username)
            state = .unlocked(since: clock())
            infoMessage = persistInDevice
                ? "Token importado y guardado en este dispositivo."
                : "Token importado. No se ha guardado: necesitarás importarlo de nuevo al reabrir la app."
        } catch EncryptionPasswordCoordinator.SetupError.alreadyConfigured {
            errorMessage = "Ya hay cifrado configurado. Resetea primero para importar uno distinto."
        } catch EncryptionPasswordCoordinator.ImportError.malformedBundle,
                is DecodingError {
            errorMessage = "El archivo no es un token de cifrado válido."
        } catch EncryptionPasswordCoordinator.ImportError.unsupportedVersion(let v) {
            errorMessage = "Versión del archivo no soportada (\(v))."
        } catch {
            errorMessage = "No se pudo importar el token."
        }
    }

    /// Genera el bundle exportable a partir del token persistido en
    /// Keychain. Devuelve nil si el token no está guardado en este
    /// dispositivo (caso "Guardar en este dispositivo" desactivado).
    func exportTokenBundle() -> EncryptionTokenBundle? {
        if let fresh = freshlyGeneratedBundle {
            return fresh
        }
        return try? coordinator.exportableBundle(forUsername: username)
    }

    /// Cierra el sheet de presentación del token recién generado.
    func dismissFreshTokenSheet() {
        freshlyGeneratedBundle = nil
    }

    /// Resetea destructivamente la configuración. Los archivos cifrados
    /// con la key anterior quedan inaccesibles para siempre.
    func resetEncryption() async {
        isWorking = true
        defer { isWorking = false }

        do {
            try coordinator.reset(forUsername: username)
            unlockedKey = nil
            keyVault?.lock()
            freshlyGeneratedBundle = nil
            state = .notConfigured
            infoMessage = "Configuración de cifrado eliminada."
        } catch {
            errorMessage = "No se pudo resetear el cifrado."
        }
    }

    func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }
}
