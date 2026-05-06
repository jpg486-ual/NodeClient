//
//  NodeClientApp.swift
//  NodeClient
//
//  Created by José Esteban Pérez González on 11/2/26.
//

import SwiftUI

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@main
struct NodeClientApp: App {
    @StateObject private var sessionStore = SessionStore()

    // Wire-up del scheduler macOS. Se mantiene como state
    // fuerte para que NSBackgroundActivityScheduler no se libere.
    // En iOS el manejo se hace via .backgroundTask(.appRefresh) que
    // captura el handler en el scope del Scene.
    #if os(macOS)
    @State private var macSchedulerRef: AnyObject?
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionStore)
                .onAppear {
                    activateBackgroundSyncIfNeeded()
                    migrateEncryptionKeychainIfNeeded()
                    unlockEncryptionVaultIfPossible()
                    refreshSessionTokenIfNeeded()
                }
                .onReceive(sessionStore.$username) { newUsername in
                    handleUsernameChange(newUsername)
                }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundSyncIdentifier.appRefresh)) {
            // BGTask handler: instancia un coordinator on-demand.
            await runBackgroundSyncTask()
        }
        #endif
    }

    /// Crea un coordinator funcional desde el composition root y dispara
    /// una pasada de sync background. Returns true si exitoso.
    /// Stores construidos vía `NodeClientAppGroups.makeShared*`
    @MainActor
    private func runBackgroundSyncTask() async -> Bool {
        let api = NodeAPIClient(baseURL: NodeAPIClient.resolveBaseURL(from: sessionStore.baseURL))
        let telemetry = NodeClientAppGroups.makeSharedTelemetry()
        let syncStore = NodeClientAppGroups.makeSharedSyncStateStore()
        let repository = DefaultFilesRepository(
            apiClient: api,
            syncStateStore: syncStore,
            telemetryStore: telemetry
        )
        let coordinator = BackgroundSyncCoordinator(
            sessionStore: sessionStore,
            repository: repository,
            telemetry: telemetry
        )
        let success = await coordinator.performBackgroundSync()

        #if os(iOS)
        IOSBackgroundSyncScheduler().scheduleNextRefresh()
        #endif

        return success
    }

    /// One-shot: copia el config de cifrado del keychain legacy
    /// (sin access group, solo visible para la app) al keychain
    /// compartido (con access group, infraestructura preparada para
    /// las direcciones futuras). Idempotente: si el
    /// shared ya tiene verifier, no toca nada. Si el usuario no ha
    /// iniciado sesión nunca o el legacy keychain está vacío, no-op.
    @MainActor
    private func migrateEncryptionKeychainIfNeeded() {
        guard let username = sessionStore.username, !username.isEmpty else {
            return
        }
        EncryptionPasswordCoordinator.migrateLegacyToShared(
            username: username,
            legacy: KeychainEncryptionPasswordStore(),
            shared: NodeClientAppGroups.makeSharedEncryptionPasswordStore()
        )
    }

    /// Reacciona al cambio del username publicado por `SessionStore`. Este
    /// hook complementa el `unlockEncryptionVaultIfPossible` de `.onAppear`
    /// para dos escenarios donde el de arranque no basta:
    ///
    ///  1. Tras una reinstalación que invalida el Keychain del token de
    ///     sesión (típico de Xcode build & run con firma cambiante): la
    ///     app recibe al usuario en LoginView, `.onAppear` corrió sin
    ///     sesión y abortó. Tras login con un usuario
    ///     distinto al previo el username transiciona vacío→valor y el
    ///     unlock debe re-ejecutarse.
    ///  2. Cuando el usuario activo cambia con el vault todavía cargado
    ///     con la key del usuario anterior: hay que descartarla antes de
    ///     intentar derivar la del nuevo, para no cifrar con clave ajena.
    ///
    /// Es idempotente: si el vault ya tiene la key del username actual, no
    /// hace nada.
    @MainActor
    private func handleUsernameChange(_ newUsername: String?) {
        let trimmed = newUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            // Logout / sin sesión: el `SessionLogoutCleaner` y el flujo de
            // logout son responsables de limpiar el vault. Aquí no tocamos.
            return
        }
        if EncryptionKeyVault.shared.currentUsername == trimmed,
           EncryptionKeyVault.shared.isUnlocked {
            return
        }
        if let activeUser = EncryptionKeyVault.shared.currentUsername,
           activeUser != trimmed {
            EncryptionKeyVault.shared.lock()
        }
        unlockEncryptionVaultIfPossible()
    }

    /// Auto-unlock del `EncryptionKeyVault` al arranque si el usuario
    /// previamente eligió "Guardar en este dispositivo" — el token + salt
    /// + iterations + verifier viven en el shared Keychain (App Group).
    /// Sin este hook el vault arranca vacío y los uploads/downloads de
    /// FilesView no aplicarían cifrado/descifrado hasta que el usuario
    /// abriese manualmente Settings → Cifrado (que dispara
    /// `EncryptionSettingsViewModel.refreshState`). No hace nada si:
    ///  - no hay sesión,
    ///  - no hay token persistido (caso "no guardar en dispositivo": el
    ///    usuario debe re-importar manualmente cada arranque),
    ///  - el verifier no cuadra (corrupción) — el caso normal de "no
    ///    configurado" simplemente devuelve `notConfigured` y silencio.
    @MainActor
    private func unlockEncryptionVaultIfPossible() {
        guard let username = sessionStore.username?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty else {
            return
        }
        let coordinator = EncryptionPasswordCoordinator(
            derivation: PasswordKeyDerivation(),
            store: NodeClientAppGroups.makeSharedEncryptionPasswordStore()
        )
        guard let key = try? coordinator.unlockFromStoredToken(forUsername: username) else {
            return
        }
        EncryptionKeyVault.shared.unlock(key: key, forUsername: username)
    }

    /// Llama al `SessionRefreshCoordinator` al arrancar la app. Si el
    /// token entra en la ventana de margen (1h pre-expiración) se refresca
    /// proactivamente y se actualiza el SessionStore. Si el server devuelve
    /// 401 (token revocado o expirado pre-refresh), `SessionStore.logout()`
    /// limpia la sesión y `ContentView` reactivo muestra LoginView.
    /// No-op si no hay sesión activa.
    @MainActor
    private func refreshSessionTokenIfNeeded() {
        guard let token = sessionStore.sessionToken, !token.isEmpty else {
            return
        }
        Task {
            let api = NodeAPIClient(
                baseURL: NodeAPIClient.resolveBaseURL(from: sessionStore.baseURL)
            )
            let coordinator = NodeClientAppGroups.makeSharedRefreshCoordinator(apiClient: api)
            let result = await coordinator.ensureFreshTokenIfNeeded()
            switch result {
            case let .refreshed(newToken, newExpiresAt):
                // Re-publicar al SessionStore para que las VMs vivas
                // (FilesViewModel, etc) reciban el cambio observado.
                sessionStore.updateSession(
                    baseURL: sessionStore.baseURL,
                    token: newToken,
                    username: sessionStore.username,
                    quotaMb: sessionStore.quotaMb,
                    expiresAt: newExpiresAt
                )

            case .expired:
                // Auto-logout por token revocado: usar el cleaner para que
                // el árbol del usuario expirado no quede en SQLite a la vista
                // del siguiente que entre.
                SessionLogoutCleaner.performLocalLogoutCleanup(sessionStore: sessionStore)

            case .stillValid, .noActiveSession:
                break
            }
        }
    }

    @MainActor
    private func activateBackgroundSyncIfNeeded() {
        #if os(iOS)
        // Programar primera ventana al arrancar. iOS decide cuándo ejecutar.
        IOSBackgroundSyncScheduler().scheduleNextRefresh()
        #elseif os(macOS)
        guard macSchedulerRef == nil else { return }
        let scheduler = MacOSBackgroundSyncScheduler {
            _ = await runBackgroundSyncTask()
        }
        scheduler.scheduleNextRefresh()
        macSchedulerRef = scheduler
        #endif
    }
}
