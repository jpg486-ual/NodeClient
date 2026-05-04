import CryptoKit
import Foundation
@testable import NodeClientCore
import XCTest

final class NodeAPIClientRealNodeIntegrationTests: XCTestCase {
    private struct RealNodeConfig {
        let baseURL: URL
        let username: String
        let password: String
    }

    func test_realNode_loginRefreshLogoutFlow() async throws {
        let config = try configurationOrSkip()
        let client = makeClient(baseURL: config.baseURL)

        let login = try await client.login(username: config.username, password: config.password)
        XCTAssertEqual(login.username, config.username)
        XCTAssertFalse(login.token.isEmpty)

        let refreshed = try await client.refresh(token: login.token)
        XCTAssertEqual(refreshed.username, config.username)
        XCTAssertFalse(refreshed.token.isEmpty)

        try await client.logout(token: refreshed.token)
    }

    func test_realNode_uploadDownloadRoundTrip_withChecksum() async throws {
        let config = try configurationOrSkip()
        let client = makeClient(baseURL: config.baseURL)

        let login = try await client.login(username: config.username, password: config.password)
        let token = login.token

        let entryId = UUID().uuidString
        let remotePath = "/nodeclient-ci-\(entryId).bin"
        let payload = Data("nodeclient-real-contract-\(entryId)".utf8)
        let checksum = Self.sha256Hex(payload)

        let upsertedEntry = try await client.upsertEntry(
            token: token,
            request: FsUpsertEntryRequest(
                entryId: entryId,
                path: remotePath,
                entryType: .file,
                sizeBytes: Int64(payload.count),
                checksum: checksum,
                deleted: false
            )
        )
        let canonicalEntryId = upsertedEntry.entryId

        let uploadSession = try await client.createUploadSession(
            token: token,
            request: FileUploadSessionCreateRequest(entryId: canonicalEntryId)
        )

        _ = try await client.appendUploadChunk(
            token: token,
            sessionId: uploadSession.sessionId,
            offset: 0,
            chunk: payload
        )

        let completion = try await client.completeUploadSession(token: token, sessionId: uploadSession.sessionId)

        XCTAssertEqual(completion.entryId, canonicalEntryId)
        XCTAssertEqual(completion.sizeBytes, Int64(payload.count))
        XCTAssertEqual(completion.checksum.lowercased(), checksum)

        let downloaded = try await client.downloadFileContent(token: token, entryId: canonicalEntryId) { _ in }
        XCTAssertEqual(downloaded, payload)

        try await client.logout(token: token)
    }

    func test_realNode_fetchTreeInvalidCursor_returnsStableContractError() async throws {
        let config = try configurationOrSkip()
        let client = makeClient(baseURL: config.baseURL)

        let login = try await client.login(username: config.username, password: config.password)

        do {
            _ = try await client.fetchTree(token: login.token, sinceCursor: -1)
            XCTFail("Expected NodeAPIError.api for invalid sinceCursor")
        } catch let error as NodeAPIError {
            guard case .api(let statusCode, let errorCode, _) = error else {
                XCTFail("Unexpected NodeAPIError: \(error)")
                return
            }
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(errorCode, "FS_TREE_INVALID_REQUEST")
        }

        try await client.logout(token: login.token)
    }

    private func configurationOrSkip() throws -> RealNodeConfig {
        let environment = ProcessInfo.processInfo.environment

        guard environment["REAL_NODE_INTEGRATION"] == "true" else {
            throw XCTSkip(
                "Real-node integration desactivada. Define REAL_NODE_INTEGRATION=true junto con REAL_NODE_BASE_URL, REAL_NODE_USERNAME y REAL_NODE_PASSWORD."
            )
        }

        guard
            let baseURLString = environment["REAL_NODE_BASE_URL"],
            let username = environment["REAL_NODE_USERNAME"],
            let password = environment["REAL_NODE_PASSWORD"],
            let baseURL = URL(string: baseURLString),
            baseURL.scheme != nil,
            baseURL.host != nil,
            !username.isEmpty,
            !password.isEmpty
        else {
            throw XCTSkip(
                "Variables de entorno incompletas para integración real: REAL_NODE_BASE_URL, REAL_NODE_USERNAME, REAL_NODE_PASSWORD."
            )
        }

        return RealNodeConfig(baseURL: baseURL, username: username, password: password)
    }

    private func makeClient(baseURL: URL) -> NodeAPIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 15
        sessionConfiguration.timeoutIntervalForResource = 60
        return NodeAPIClient(baseURL: baseURL, session: URLSession(configuration: sessionConfiguration))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
