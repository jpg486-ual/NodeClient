//  TDD para `MoreViewModel.refreshProfile`.
//
//  GET /auth/me actualiza username, quotaMb y `role`;
//  `usedBytes` se deriva localmente sumando `entry.sizeBytes` del
//  snapshot SQLite filtrando `!deleted && entryType == .file`.

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class MoreViewModelProfileRefreshTests: XCTestCase {
    func test_refreshProfile_callsApiAndUpdatesQuotaAndRole() async {
        let api = MockProfileAPIClient()
        api.profileResult = .success(
            AuthProfileResponse(username: "demo-jose", quotaMb: 2_048, quotaUsedBytes: nil, role: "END_USER")
        )
        let viewModel = MoreViewModel(apiClientFactory: { _ in api })
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "tok")

        await viewModel.refreshProfile(sessionStore: sessionStore)

        XCTAssertEqual(viewModel.role, "END_USER")
        XCTAssertEqual(sessionStore.quotaMb, 2_048)
        XCTAssertNil(viewModel.profileRefreshError)
        XCTAssertFalse(viewModel.isRefreshingProfile)
    }

    func test_refreshProfile_withoutSession_recomputesUsedBytesAndSkipsApi() async {
        let api = MockProfileAPIClient()
        let snapshot = FilesSyncSnapshot(
            cursor: 1,
            entries: [
                FilesSyncEntry(
                    entryId: "e1",
                    path: "/a.bin",
                    entryType: .file,
                    sizeBytes: 1_000,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(),
                    deleted: false
                ),
                FilesSyncEntry(
                    entryId: "e2",
                    path: "/b.bin",
                    entryType: .file,
                    sizeBytes: 500,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(),
                    deleted: false
                ),
                FilesSyncEntry(
                    entryId: "e3",
                    path: "/c.bin",
                    entryType: .file,
                    sizeBytes: 9_999,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(),
                    deleted: true
                )
            ]
        )
        let store = SeededSyncStore(snapshot: snapshot)
        let viewModel = MoreViewModel(apiClientFactory: { _ in api }, syncStateStore: store)
        let sessionStore = SessionStore(
            userDefaults: testDefaults(),
            tokenStore: InMemoryTokenStore()
        )

        await viewModel.refreshProfile(sessionStore: sessionStore)

        XCTAssertEqual(api.fetchProfileCallCount, 0)
        XCTAssertEqual(viewModel.usedBytes, 1_500)  // 1000 + 500, e3 excluído por deleted
    }

    func test_refreshProfile_apiError_setsErrorMessage() async {
        let api = MockProfileAPIClient()
        api.profileResult = .failure(.unauthorized)
        let viewModel = MoreViewModel(apiClientFactory: { _ in api })
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "tok")

        await viewModel.refreshProfile(sessionStore: sessionStore)

        XCTAssertNotNil(viewModel.profileRefreshError)
    }

    /// Cuando el backend devuelve `quotaUsedBytes` (RS-inflated autoritativo),
    /// `usedBytes` debe reflejar ese valor — NO la suma raw del SQLite.
    /// Bug 2026-05-09: la UI mostraba 323 KB para un archivo de 323 KB con
    /// RS(3,2) que el backend cobraba como 484.5 KB inflated.
    func test_refreshProfile_usesBackendQuotaUsedBytesAsAuthoritative() async {
        let api = MockProfileAPIClient()
        // Backend reporta 484500 bytes (323 KB raw × 3 / 2).
        api.profileResult = .success(
            AuthProfileResponse(
                username: "paco",
                quotaMb: 256,
                quotaUsedBytes: 484_500,
                role: "END_USER"
            )
        )
        // SQLite local sugiere otro valor (323000 raw) — no debe ganar.
        let snapshot = FilesSyncSnapshot(
            cursor: 1,
            entries: [
                FilesSyncEntry(
                    entryId: "e1",
                    path: "/foto.png",
                    entryType: .file,
                    sizeBytes: 323_000,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(),
                    deleted: false
                )
            ]
        )
        let store = SeededSyncStore(snapshot: snapshot)
        let viewModel = MoreViewModel(apiClientFactory: { _ in api }, syncStateStore: store)
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "tok")

        await viewModel.refreshProfile(sessionStore: sessionStore)

        XCTAssertEqual(viewModel.usedBytes, 484_500, "Backend RS-inflated wins over raw SQLite sum")
        XCTAssertEqual(sessionStore.quotaUsedBytes, 484_500)
    }

    /// Si el backend falla pero hay snapshot SQLite, `usedBytes` cae al
    /// fallback raw (degradación elegante). El error sigue surfaceándose
    /// en `profileRefreshError`.
    func test_refreshProfile_apiError_fallsBackToSnapshotUsedBytes() async {
        let api = MockProfileAPIClient()
        api.profileResult = .failure(.unauthorized)
        let snapshot = FilesSyncSnapshot(
            cursor: 1,
            entries: [
                FilesSyncEntry(
                    entryId: "e1",
                    path: "/a.bin",
                    entryType: .file,
                    sizeBytes: 700,
                    checksum: nil,
                    version: 1,
                    updatedAt: Date(),
                    deleted: false
                )
            ]
        )
        let store = SeededSyncStore(snapshot: snapshot)
        let viewModel = MoreViewModel(apiClientFactory: { _ in api }, syncStateStore: store)
        let sessionStore = makeSessionStore(baseURL: "http://localhost:8081", token: "tok")

        await viewModel.refreshProfile(sessionStore: sessionStore)

        XCTAssertNotNil(viewModel.profileRefreshError)
        XCTAssertEqual(viewModel.usedBytes, 700, "Fallback al snapshot raw cuando backend falla")
    }
    
    // MARK: - Helpers

    private func testDefaults() -> UserDefaults {
        let suite = "more-profile-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSessionStore(baseURL: String, token: String) -> SessionStore {
        let defaults = testDefaults()
        defaults.set(baseURL, forKey: SessionStore.baseURLKey)
        let tokenStore = InMemoryTokenStore()
        try? tokenStore.writeToken(token)
        return SessionStore(userDefaults: defaults, tokenStore: tokenStore)
    }
}

private final class MockProfileAPIClient: NodeAPIClientProtocol {
    var profileResult: Result<AuthProfileResponse, NodeAPIError> = .success(
        AuthProfileResponse(username: "x", quotaMb: 0, quotaUsedBytes: nil, role: nil)
    )
    private(set) var fetchProfileCallCount = 0

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        Data()
    }

    func logout(token: String) async throws {}

    func fetchProfile(token: String) async throws -> AuthProfileResponse {
        fetchProfileCallCount += 1
        return try profileResult.get()
    }
}

private final class SeededSyncStore: FilesSyncStateStore {
    private let snapshot: FilesSyncSnapshot

    init(snapshot: FilesSyncSnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { snapshot }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private final class InMemoryTokenStore: SessionTokenStore {
    private var token: String?

    func readToken() throws -> String? { token }
    func writeToken(_ value: String) throws { token = value }
    func deleteToken() throws { token = nil }
}
