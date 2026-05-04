@testable import NodeClientCore
import XCTest

@MainActor
final class LoginViewModelTests: XCTestCase {
    func test_login_whenCredentialsAreValid_updatesSessionStore() async {
        let apiClient = MockLoginNodeAPIClient()
        apiClient.loginResult = .success(
            AuthLoginResponse(
                token: "jwt-123",
                username: "jose",
                quotaMb: 1_024,
                expiresAt: Date()
            )
        )

        let (sessionStore, defaultsName) = makeSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

        let viewModel = LoginViewModel(baseURL: "http://localhost:8081") { _ in apiClient }
        viewModel.username = " jose "
        viewModel.password = " secret "

        await viewModel.login(sessionStore: sessionStore)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(sessionStore.baseURL, "http://localhost:8081")
        XCTAssertEqual(sessionStore.sessionToken, "jwt-123")
        XCTAssertEqual(sessionStore.username, "jose")
        XCTAssertEqual(
            sessionStore.quotaMb,
            1_024,
            "La quota viene en AuthLoginResponse y debe propagarse al SessionStore"
        )
    }

    func test_login_whenUnauthorized_showsInvalidCredentialsMessage() async {
        let apiClient = MockLoginNodeAPIClient()
        apiClient.loginResult = .failure(.unauthorized)

        let (sessionStore, defaultsName) = makeSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

        let viewModel = LoginViewModel(baseURL: "http://localhost:8081") { _ in apiClient }
        viewModel.username = "jose"
        viewModel.password = "wrong"

        await viewModel.login(sessionStore: sessionStore)

        XCTAssertEqual(viewModel.errorMessage, "Invalid credentials.")
        XCTAssertNil(sessionStore.sessionToken)
    }

    func test_login_whenBaseURLIsInvalid_showsValidationError() async {
        let (sessionStore, defaultsName) = makeSessionStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

        let viewModel = LoginViewModel(baseURL: "not-a-url")
        viewModel.username = "jose"
        viewModel.password = "secret"

        await viewModel.login(sessionStore: sessionStore)

        XCTAssertEqual(viewModel.errorMessage, "Base URL is invalid.")
    }

    func test_login_failure_recordsErrorTraceForQA() async {
        let apiClient = MockLoginNodeAPIClient()
        apiClient.loginResult = .failure(.unauthorized)

        let defaultsName = "LoginViewModelTests.Observability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let observability = UserDefaultsObservabilityStore(userDefaults: defaults)
        let sessionStore = SessionStore(userDefaults: defaults, tokenStore: TestSessionTokenStore())

        let viewModel = LoginViewModel(
            baseURL: "http://localhost:8081",
            apiClientFactory: { _ in apiClient },
            observabilityStore: observability
        )
        viewModel.username = "jose"
        viewModel.password = "wrong"

        await viewModel.login(sessionStore: sessionStore)

        let traces = observability.recentTraces(limit: 20, minimumLevel: .error)
        XCTAssertTrue(traces.contains { $0.category == "auth" && $0.event == "login.failed" })
    }

    private func makeSessionStore() -> (SessionStore, String) {
        let suiteName = "LoginViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let tokenStore = TestSessionTokenStore()
        return (SessionStore(userDefaults: defaults, tokenStore: tokenStore), suiteName)
    }
}

private final class MockLoginNodeAPIClient: NodeAPIClientProtocol {
    var loginResult: Result<AuthLoginResponse, NodeAPIError> = .success(
        AuthLoginResponse(token: "", username: "", quotaMb: 0, expiresAt: Date())
    )

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        try loginResult.get()
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}
}

private final class TestSessionTokenStore: SessionTokenStore {
    private var token: String?

    func readToken() throws -> String? {
        token
    }

    func writeToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
    }
}
