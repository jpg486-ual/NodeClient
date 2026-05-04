//  Preferencias persistentes del subsistema de cifrado del cliente.
//  El toggle "comprimir antes de cifrar" se guarda en UserDefaults para
//  que al reabrir la app la preferencia se respete sin extra signal.
//
//  Default ON: el ahorro típico (texto, JSON, código fuente, .docx, etc.)
//  ronda el 30-60% antes del cifrado, lo que se traduce en un 30-60%
//  menos de cuota consumida y de ancho de banda transferido. La heurística
//  per-frame de `Nce3StreamingCipher` rechaza la compresión cuando el ratio
//  no llega al 10% (archivos ya comprimidos), así que el coste es prácticamente
//  nulo en formatos que no se benefician.

import Combine
import Foundation

protocol EncryptionPreferencesStore {
    var compressionEnabled: Bool { get set }
}

final class UserDefaultsEncryptionPreferencesStore: EncryptionPreferencesStore {
    static let compressionEnabledKey = "nodeclient.encryption.compressionEnabled"

    private let defaults: UserDefaults

    /// `defaults` defaultea al App Group compartido para que las
    /// extensiones lean la misma preferencia que la app
    /// principal. Tests pueden inyectar `.standard` o un suite mock.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? NodeClientAppGroups.sharedUserDefaults()
    }

    var compressionEnabled: Bool {
        get {
            // No hay valor → default ON (UserDefaults.bool devuelve `false`
            // para keys ausentes; invertimos con un check `object(forKey:)`).
            if defaults.object(forKey: Self.compressionEnabledKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.compressionEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: Self.compressionEnabledKey)
        }
    }
}

/// Observable wrapper para SwiftUI binding directo al toggle.
@MainActor
final class EncryptionPreferences: ObservableObject {
    static let shared = EncryptionPreferences()

    @Published var compressionEnabled: Bool {
        didSet {
            store.compressionEnabled = compressionEnabled
        }
    }

    private var store: EncryptionPreferencesStore

    init(store: EncryptionPreferencesStore = UserDefaultsEncryptionPreferencesStore()) {
        self.store = store
        self.compressionEnabled = store.compressionEnabled
    }
}
