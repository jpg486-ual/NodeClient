import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    static let baseURLKey = "node.baseURL"
    static let sessionTokenKey = "node.sessionToken"
    static let usernameKey = "node.username"
    static let quotaMbKey = "node.quotaMb"
    /// Alias del key compartido en `NodeClientAppGroups`
    /// Mantenemos el alias para no romper call sites existentes.
    static let sessionExpiresAtKey = NodeClientAppGroups.sessionExpiresAtKey

    @Published private(set) var baseURL: String
    @Published private(set) var sessionToken: String?
    @Published private(set) var username: String?
    @Published private(set) var quotaMb: Int?
    /// Live RS-inflated consumption del usuario (bytes). nil hasta el
    /// primer `refreshProfile` exitoso. Usado por FilesViewModel para
    /// pre-check de cuota antes de iniciar uploads grandes.
    @Published private(set) var quotaUsedBytes: Int64?
    @Published private(set) var sessionExpiresAt: Date?
    @Published private(set) var sessionWarningMessage: String?

    init(
        userDefaults: UserDefaults? = nil,
        tokenStore: SessionTokenStore? = nil
    ) {
        // App Group + access group: garantiza que las futuras
        // extensiones lean exactamente los mismos baseURL/username/token.
        // Sin esto, la extensión cae a defaults y muestra "lista vacía"
        // o "sincronización en pausa" porque su `fetchTree` se autentica
        // con un token que no existe en su Keychain.
        let resolvedDefaults = userDefaults ?? NodeClientAppGroups.sharedUserDefaults()
        let resolvedTokenStore = tokenStore ?? NodeClientAppGroups.makeSharedTokenStore()
        self.userDefaults = resolvedDefaults
        self.tokenStore = resolvedTokenStore
        self.baseURL = resolvedDefaults.string(forKey: Self.baseURLKey) ?? "http://localhost:8081"
        let storedUsername = resolvedDefaults.string(forKey: Self.usernameKey)
        self.username = storedUsername?.isEmpty == false ? storedUsername : nil
        // quotaMb persistido como Int en UserDefaults; ausencia = nil (no 0).
        if resolvedDefaults.object(forKey: Self.quotaMbKey) is Int {
            self.quotaMb = resolvedDefaults.integer(forKey: Self.quotaMbKey)
        } else {
            self.quotaMb = nil
        }

        // expiresAt persistido como Double (timeIntervalSince1970). Si no
        // hay valor → nil. La validación de expiración la hace el
        // `SessionRefreshCoordinator` en cada operación; aquí solo
        // restauramos el estado para evitar lookups extra.
        if let expiresAtRaw = resolvedDefaults.object(forKey: Self.sessionExpiresAtKey) as? Double {
            self.sessionExpiresAt = Date(timeIntervalSince1970: expiresAtRaw)
        } else {
            self.sessionExpiresAt = nil
        }

        if let quotaUsedRaw = resolvedDefaults.object(forKey: NodeClientAppGroups.quotaUsedBytesKey) as? Double {
            self.quotaUsedBytes = Int64(quotaUsedRaw)
        } else {
            self.quotaUsedBytes = nil
        }

        let secureToken = try? resolvedTokenStore.readToken()
        if let secureToken, !secureToken.isEmpty {
            self.sessionToken = secureToken
            resolvedDefaults.removeObject(forKey: Self.sessionTokenKey)
        } else {
            let legacyToken = resolvedDefaults.string(forKey: Self.sessionTokenKey)
            if let legacyToken, !legacyToken.isEmpty {
                self.sessionToken = legacyToken
                do {
                    try resolvedTokenStore.writeToken(legacyToken)
                    resolvedDefaults.removeObject(forKey: Self.sessionTokenKey)
                } catch {
                    self.sessionWarningMessage = "Could not migrate legacy session token to secure storage."
                }
            } else {
                self.sessionToken = nil
            }
        }
    }

    var isAuthenticated: Bool {
        guard let token = sessionToken else {
            return false
        }
        return !token.isEmpty
    }

    var syncNamespace: String {
        if let username, !username.isEmpty {
            return username
        }
        return "anonymous"
    }

    func updateSession(
        baseURL: String,
        token: String,
        username: String? = nil,
        quotaMb: Int? = nil,
        expiresAt: Date? = nil,
        quotaUsedBytes: Int64? = nil
    ) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.baseURL = trimmedBaseURL
        self.sessionToken = trimmedToken
        self.username = (trimmedUsername?.isEmpty == false) ? trimmedUsername : nil
        self.quotaMb = quotaMb
        self.quotaUsedBytes = quotaUsedBytes
        self.sessionExpiresAt = expiresAt
        self.sessionWarningMessage = nil

        userDefaults.set(trimmedBaseURL, forKey: Self.baseURLKey)
        userDefaults.removeObject(forKey: Self.sessionTokenKey)
        if let username = self.username {
            userDefaults.set(username, forKey: Self.usernameKey)
        } else {
            userDefaults.removeObject(forKey: Self.usernameKey)
        }
        if let quotaMb {
            userDefaults.set(quotaMb, forKey: Self.quotaMbKey)
        } else {
            userDefaults.removeObject(forKey: Self.quotaMbKey)
        }
        if let expiresAt {
            userDefaults.set(expiresAt.timeIntervalSince1970, forKey: Self.sessionExpiresAtKey)
        } else {
            userDefaults.removeObject(forKey: Self.sessionExpiresAtKey)
        }
        if let quotaUsedBytes {
            userDefaults.set(Double(quotaUsedBytes), forKey: NodeClientAppGroups.quotaUsedBytesKey)
        } else {
            userDefaults.removeObject(forKey: NodeClientAppGroups.quotaUsedBytesKey)
        }

        do {
            try tokenStore.writeToken(trimmedToken)
        } catch {
            sessionWarningMessage = "Could not save session token in secure storage."
        }
        // Persistir username en keychain (mismo access group) además
        // del shared UserDefaults — las extensiones lo necesitan para
        // resolver el namespace del usuario y leer items de cifrado.
        // En setups donde el App Group no funciona runtime pero el
        // keychain sí (frecuente en dev macOS), ésta es la fuente
        // de verdad confiable.
        if let username = self.username {
            try? tokenStore.writeUsername(username)
        } else {
            try? tokenStore.deleteUsername()
        }
    }

    func logout() {
        sessionWarningMessage = nil
        sessionToken = nil
        username = nil
        quotaMb = nil
        quotaUsedBytes = nil
        sessionExpiresAt = nil
        userDefaults.removeObject(forKey: Self.sessionTokenKey)
        userDefaults.removeObject(forKey: Self.usernameKey)
        userDefaults.removeObject(forKey: Self.quotaMbKey)
        userDefaults.removeObject(forKey: Self.sessionExpiresAtKey)
        userDefaults.removeObject(forKey: NodeClientAppGroups.quotaUsedBytesKey)

        do {
            try tokenStore.deleteToken()
        } catch {
            sessionWarningMessage = "Could not clear secure session token."
        }
        try? tokenStore.deleteUsername()
    }

    private let userDefaults: UserDefaults
    private let tokenStore: SessionTokenStore
}
