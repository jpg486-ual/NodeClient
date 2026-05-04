//  Cache thread-safe de la `SymmetricKey` derivada vía PBKDF2.
//
//  PBKDF2 con 100k+ iteraciones cuesta ~100ms cada vez.
//
//  La key se cachea hasta `ttl` (default 5 min) o hasta que cambie
//  el username asociado. NUNCA persiste a disco;
//  vive solo en memoria del proceso. Tras crash/reinicio la key se
//  re-deriva al primer acceso.

import CryptoKit
import Foundation

final class EncryptionKeyCache {
    private struct Entry {
        let key: SymmetricKey
        let username: String
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cached: Entry?

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// Devuelve la key cacheada si sigue válida y el username coincide.
    /// Si no, intenta resolver via `coordinator.resolveCurrentKey` y
    /// cachea el resultado. Devuelve nil si el coordinator no puede
    /// derivar la key (sin token persistido, cifrado no configurado).
    func resolve(
        username: String,
        coordinator: EncryptionPasswordCoordinator,
        clock: () -> Date = Date.init
    ) -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        if let cached, cached.username == username, cached.expiresAt > now {
            return cached.key
        }

        guard let resolved = coordinator.resolveCurrentKey(forUsername: username) else {
            self.cached = nil
            return nil
        }
        self.cached = Entry(
            key: resolved,
            username: username,
            expiresAt: now.addingTimeInterval(ttl)
        )
        return resolved
    }

    /// Invalidación manual — útil tras logout o reset de cifrado.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
