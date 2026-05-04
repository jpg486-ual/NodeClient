//  TDD para `RegisterViewModel`.
//
//  registro + autologin transparente. El backend NO
//  devuelve token tras register, así que el ViewModel encadena un
//  login interno con las credenciales recién enviadas y persiste el
//  token resultante en SessionStore.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class RegisterViewModelTests: XCTestCase {
    func test_register_success_callsApiThenAutologinAndPersistsSession() async {
        let apiClient = MockRegisterAPIClient()
        let sessionStore = makeSessionStore()
        let viewModel = makeViewModel(apiClient: apiClient)
        viewModel.invitationCode = "NCDEMO1234567890"
        viewModel.username = "demo-jose"
        viewModel.password = "secret-2026"
        viewModel.confirmPassword = "secret-2026"

        await viewModel.register(sessionStore: sessionStore)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(apiClient.lastRegisterRequest?.invitationCode, "NCDEMO1234567890")
        XCTAssertEqual(apiClient.lastRegisterRequest?.username, "demo-jose")
        XCTAssertEqual(apiClient.lastLoginUsername, "demo-jose")
        XCTAssertEqual(sessionStore.username, "demo-jose")
        XCTAssertEqual(sessionStore.quotaMb, 1_024)
        XCTAssertEqual(sessionStore.sessionToken, "auto-login-token")
    }

    func test_register_invitationNotFound_setsErrorAndDoesNotLogin() async {
        let apiClient = MockRegisterAPIClient()
        apiClient.registerHandler = { _ in
            throw NodeAPIError.api(statusCode: 404, errorCode: "INVITATION_CODE_NOT_FOUND", message: "not found")
        }
        let sessionStore = makeSessionStore()
        let viewModel = makeViewModel(apiClient: apiClient)
        viewModel.invitationCode = "BAD"
        viewModel.username = "user"
        viewModel.password = "secret"
        viewModel.confirmPassword = "secret"

        await viewModel.register(sessionStore: sessionStore)

        XCTAssertEqual(viewModel.errorMessage, "Invitation code not found or already used.")
        XCTAssertNil(apiClient.lastLoginUsername)
        XCTAssertNil(sessionStore.sessionToken)
    }

    func test_register_passwordMismatch_setsValidationErrorWithoutCallingApi() async {
        let apiClient = MockRegisterAPIClient()
        let sessionStore = makeSessionStore()
        let viewModel = makeViewModel(apiClient: apiClient)
        viewModel.invitationCode = "code"
        viewModel.username = "user"
        viewModel.password = "secret"
        viewModel.confirmPassword = "secret-different"

        await viewModel.register(sessionStore: sessionStore)

        XCTAssertEqual(viewModel.errorMessage, "Passwords don't match.")
        XCTAssertNil(apiClient.lastRegisterRequest)
    }

    func test_register_emptyInvitationCode_setsValidationError() async {
        let viewModel = makeViewModel(apiClient: MockRegisterAPIClient())
        viewModel.invitationCode = "  "
        viewModel.username = "user"
        viewModel.password = "secret"
        viewModel.confirmPassword = "secret"

        await viewModel.register(sessionStore: makeSessionStore())

        XCTAssertEqual(viewModel.errorMessage, "Invitation code is required.")
    }

    func test_register_invalidBaseURL_setsValidationError() async {
        let viewModel = RegisterViewModel(
            baseURL: "no-scheme",
            apiClientFactory: { _ in MockRegisterAPIClient() }
        )
        viewModel.invitationCode = "c"
        viewModel.username = "u"
        viewModel.password = "p"
        viewModel.confirmPassword = "p"

        await viewModel.register(sessionStore: makeSessionStore())

        XCTAssertEqual(viewModel.errorMessage, "Base URL is invalid.")
    }

    func test_register_succeedsButAutologinFails_messageHintsToSignIn() async {
        let apiClient = MockRegisterAPIClient()
        apiClient.loginHandler = { _, _ in
            throw NodeAPIError.unauthorized
        }
        let sessionStore = makeSessionStore()
        let viewModel = makeViewModel(apiClient: apiClient)
        viewModel.invitationCode = "code"
        viewModel.username = "user"
        viewModel.password = "secret"
        viewModel.confirmPassword = "secret"

        await viewModel.register(sessionStore: sessionStore)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.errorMessage?.contains("Account created"), true)
        XCTAssertNil(sessionStore.sessionToken)
    }

    // MARK: - Helpers

    private func makeViewModel(apiClient: MockRegisterAPIClient) -> RegisterViewModel {
        RegisterViewModel(
            baseURL: "http://localhost:8081",
            apiClientFactory: { _ in apiClient }
        )
    }

    private func makeSessionStore() -> SessionStore {
        let suite = "register-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SessionStore(
            userDefaults: defaults,
            tokenStore: InMemorySessionTokenStore()
        )
    }
}

private final class MockRegisterAPIClient: NodeAPIClientProtocol {
    var registerHandler: ((AuthRegisterRequest) throws -> AuthRegisterResponse)?
    var loginHandler: ((String, String) throws -> AuthLoginResponse)?
    private(set) var lastRegisterRequest: AuthRegisterRequest?
    private(set) var lastLoginUsername: String?

    func register(invitationCode: String, username: String, password: String) async throws -> AuthRegisterResponse {
        let req = AuthRegisterRequest(invitationCode: invitationCode, username: username, password: password)
        lastRegisterRequest = req
        if let handler = registerHandler {
            return try handler(req)
        }
        return AuthRegisterResponse(username: username, quotaMb: 1_024)
    }

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        lastLoginUsername = username
        if let handler = loginHandler {
            return try handler(username, password)
        }
        return AuthLoginResponse(
            token: "auto-login-token",
            username: username,
            quotaMb: 1_024,
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}
}

private final class InMemorySessionTokenStore: SessionTokenStore {
    private var token: String?

    func readToken() throws -> String? { token }
    func writeToken(_ value: String) throws { token = value }
    func deleteToken() throws { token = nil }
}
