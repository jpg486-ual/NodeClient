import Combine
import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var baseURL: String
    @Published var username: String = ""
    @Published var password: String = ""
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

    func login(sessionStore: SessionStore) async {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

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
            observabilityStore.log(
                level: .warning,
                category: "auth",
                event: "login.validation_failed",
                message: "Invalid base URL",
                metadata: ["baseURL": trimmedBaseURL]
            )
            errorMessage = "Base URL is invalid."
            return
        }

        guard !trimmedUsername.isEmpty, !trimmedPassword.isEmpty else {
            observabilityStore.log(
                level: .warning,
                category: "auth",
                event: "login.validation_failed",
                message: "Missing username or password",
                metadata: ["username": trimmedUsername, "password": trimmedPassword]
            )
            errorMessage = "Username and password are required."
            return
        }

        let startedAt = Date()
        observabilityStore.log(
            level: .info,
            category: "auth",
            event: "login.started",
            message: nil,
            metadata: ["host": parsedComponents.host ?? "unknown"]
        )

        isLoading = true
        errorMessage = nil

        do {
            let client = apiClientFactory(parsedBaseURL)
            let response = try await client.login(username: trimmedUsername, password: trimmedPassword)
            sessionStore.updateSession(
                baseURL: trimmedBaseURL,
                token: response.token,
                username: response.username,
                quotaMb: response.quotaMb,
                expiresAt: response.expiresAt
            )

            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("login.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .info,
                category: "auth",
                event: "login.succeeded",
                message: nil,
                metadata: ["durationMs": String(Int(duration))]
            )
        } catch let error as NodeAPIError {
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("login.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .error,
                category: "auth",
                event: "login.failed",
                message: Self.message(for: error),
                metadata: ["durationMs": String(Int(duration)), "errorType": String(describing: error)]
            )
            errorMessage = Self.message(for: error)
        } catch {
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            observabilityStore.recordDuration("login.latency.ms", milliseconds: duration)
            observabilityStore.log(
                level: .error,
                category: "auth",
                event: "login.failed",
                message: "Unexpected error while logging in.",
                metadata: ["durationMs": String(Int(duration))]
            )
            errorMessage = "Unexpected error while logging in."
        }

        isLoading = false
    }

    private let apiClientFactory: (URL) -> NodeAPIClientProtocol
    private let observabilityStore: ObservabilityStore

    private static func message(for error: NodeAPIError) -> String {
        switch error {
        case .unauthorized:
            return "Invalid credentials."

        case .notFound:
            return "User not found."

        case .invalidURL, .invalidResponse:
            return "Invalid node URL or response."

        case let .api(_, errorCode, message):
            switch errorCode {
            case "INVALID_CREDENTIALS":
                return "Invalid credentials."

            case "USER_NOT_FOUND":
                return "User not found."

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
