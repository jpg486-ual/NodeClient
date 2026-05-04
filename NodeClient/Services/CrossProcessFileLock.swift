//  Lock advisory `flock(2)` sobre un archivo en el App Group container.
//  Infraestructura preparada para serializar el refresh de token entre
//  procesos: con un único consumidor (la app) queda como
//  no-op funcional; reactivar coordinación cross-process si se añade
//  la extensión planificada como mejora futura.
//
//  flock funciona en el App Group container porque el sandbox de iOS
//  y macOS (con entitlement `com.apple.security.application-groups`)
//  permite operaciones POSIX sobre rutas dentro del container.
//
//  El lock es advisory — solo coordina entre procesos que se respeten
//  (los que llaman `acquire`). No hay enforcement contra procesos
//  ajenos, pero no hay tales en nuestro caso (solo app + extension).

import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct CrossProcessFileLock {
    enum LockError: Error {
        case openFailed(errno: Int32)
        case lockFailed(errno: Int32)
    }

    let path: URL

    /// Adquiere lock exclusivo bloqueante. Cierra el descriptor (y
    /// libera el lock) cuando el `Handle` devuelto se desinicializa.
    /// Si ya hay otro proceso con el lock, esta llamada bloquea hasta
    /// que el otro lo libere — generalmente <100ms (el lock solo se
    /// mantiene durante la duración de un POST /auth/refresh).
    func acquire() throws -> Handle {
        let fd = open(path.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 {
            throw LockError.openFailed(errno: errno)
        }
        let result = flock(fd, LOCK_EX)
        if result != 0 {
            let errnoSnapshot = errno
            close(fd)
            throw LockError.lockFailed(errno: errnoSnapshot)
        }
        return Handle(fd: fd)
    }

    /// RAII helper: el lock se libera al desinicializarse. Llamar
    /// `release()` explícito para liberar antes (típicamente innecesario
    /// si el caller usa `defer`).
    final class Handle {
        private var fd: Int32

        init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            guard fd >= 0 else { return }
            // flock + close libera el advisory lock automáticamente.
            close(fd)
            fd = -1
        }

        deinit {
            release()
        }
    }
}
