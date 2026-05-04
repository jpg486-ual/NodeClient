//  RegisterViewModel.
//
//  Registro con código de invitación + autologin
//  transparente. El backend devuelve `{username, quotaMb}` HTTP 201
//  pero **sin token**, así que el ViewModel encadena un `login(...)`
//  inmediato con las credenciales recién enviadas para que el usuario
//  entre directamente a FilesView sin segundo paso.

import Combine
import Foundation

@MainActor
final class RegisterViewModel: ObservableObject {
    @Published var baseURL: String
    @Published var invitationCode: String = ""
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var confirmPassword: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    init(
        baseURL: String,
        apiClientFactory: ((URL) -> NodeAPIClientProtocol)? = nil,
        observabilityStore: ObservabilityStore? = nil
    ) {
        self.baseURL = baseURL
        self.apiClientFactory = apiClientFactory ?? { NodeAPIClient(baseURL: $0) }
        self.observabilityStore = observabilityStore ?? UserDefaultsObservabilityStore()
    }

    func register(sessionStore: SessionStore) async {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        let parsedBaseURL = URL(string: trimmedBaseURL)
        let parsedComponents = parsedBaseURL.flatMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        }

        guard
            !trimmedBaseURL.isEmpty,
            let parsedBaseURL,
            let parsedComponents,
            parsedComponents.scheme?.isEmpty == false,
            parsedComponents.host?.isEmpty == false
        else {
            errorMessage = "Base URL is invalid."
            return
        }

        guard !trimmedCode.isEmpty else {
            errorMessage = "Invitation code is required."
            return
        }

        guard !trimmedUsername.isEmpty, !trimmedPassword.isEmpty else {
            errorMessage = "Username and password are required."
            return
        }

        guard trimmedPassword == trimmedConfirm else {
            errorMessage = "Passwords don't match."
            return
        }

        let startedAt = Date()
        observabilityStore.log(
            level: .info,
            category: "auth",
            event: "register.started",
            message: nil,
            metadata: ["host": parsedComponents.host ?? "unknown"]
        )

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = apiClientFactory(parsedBaseURL)

        do {
            _ = try await client.register(
                invitationCode: trimmedCode,
                username: trimmedUsername,
                password: trimmedPassword
            )
        } catch let error as NodeAPIError {
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.log(
                level: .error,
                category: "auth",
                event: "register.failed",
                message: Self.message(forRegister: error),
                metadata: ["durationMs": String(Int(duration))]
            )
            errorMessage = Self.message(forRegister: error)
            return
        } catch {
            errorMessage = "Unexpected error while registering."
            return
        }

        // Autologin transparente con las credenciales recién enviadas.
        do {
            let session = try await client.login(username: trimmedUsername, password: trimmedPassword)
            sessionStore.updateSession(
                baseURL: trimmedBaseURL,
                token: session.token,
                username: session.username,
                quotaMb: session.quotaMb,
                expiresAt: session.expiresAt
            )

            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("register.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .info,
                category: "auth",
                event: "register.succeeded",
                message: nil,
                metadata: ["durationMs": String(Int(duration))]
            )
        } catch let error as NodeAPIError {
            // Caso raro: el registro funcionó pero el autologin falló.
            // Mensaje específico para que el usuario pueda recuperar yendo
            // al LoginView con las credenciales que acaba de crear.
            errorMessage = "Account created. Please sign in: \(Self.message(forRegister: error))"
        } catch {
            errorMessage = "Account created. Please sign in manually."
        }
    }

    private let apiClientFactory: (URL) -> NodeAPIClientProtocol
    private let observabilityStore: ObservabilityStore

    private static func message(forRegister error: NodeAPIError) -> String {
        switch error {
        case .unauthorized:
            return "Invalid credentials."

        case .notFound:
            return "Invitation code not found or already used."

        case .invalidURL, .invalidResponse:
            return "Invalid node URL or response."

        case let .api(_, errorCode, message):
            switch errorCode {
            case "INVITATION_CODE_NOT_FOUND":
                return "Invitation code not found or already used."

            case "REGISTER_VALIDATION_ERROR":
                return message ?? "Registration data is invalid."

            case "USER_NOT_FOUND":
                return "User not found."

            case "INVALID_CREDENTIALS":
                return "Invalid credentials."

            default:
                return message ?? "Node returned error \(errorCode)."
            }

        case .server(let statusCode):
            return "Node returned status \(statusCode)."

        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }
}
