import Foundation
@testable import NodeClientCore
import XCTest

final class NodeAPIClientIntegrationTests: XCTestCase {
    override func tearDown() {
        URLProtocolIntegrationStub.requestHandler = nil
        super.tearDown()
    }

    func test_login_decodesIsoDateFields() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/auth/login")
            let body = """
            {
              "token": "jwt-1",
              "username": "jose",
              "quotaMb": 2048,
              "expiresAt": "2026-04-01T12:30:00Z"
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        let response = try await client.login(username: "jose", password: "secret")

        XCTAssertEqual(response.username, "jose")
        XCTAssertEqual(response.token, "jwt-1")
        XCTAssertEqual(response.quotaMb, 2_048)

        let expected = ISO8601DateFormatter().date(from: "2026-04-01T12:30:00Z")!
        XCTAssertEqual(response.expiresAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_refresh_sendsBearerAndDecodesIsoDateFields() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/auth/refresh")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-refresh-1")

            let body = """
            {
              "token": "jwt-2",
              "username": "jose",
              "quotaMb": 2048,
              "expiresAt": "2026-04-01T12:45:00Z"
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        let response = try await client.refresh(token: "token-refresh-1")

        XCTAssertEqual(response.username, "jose")
        XCTAssertEqual(response.token, "jwt-2")
        XCTAssertEqual(response.quotaMb, 2_048)

        let expected = ISO8601DateFormatter().date(from: "2026-04-01T12:45:00Z")!
        XCTAssertEqual(response.expiresAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_fetchTree_decodesSnapshotAndEntryDates() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/fs/tree")
            let body = """
            {
              "username": "jose",
              "cursor": 150,
              "snapshotAt": "2026-04-01T13:00:00Z",
              "entries": [
                {
                  "entryId": "e1",
                  "path": "/docs/a.txt",
                  "entryType": "FILE",
                  "sizeBytes": 12,
                  "checksum": "abc",
                  "version": 1,
                  "updatedAt": "2026-04-01T13:01:00Z",
                  "deleted": false
                }
              ]
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        let tree = try await client.fetchTree(token: "token", sinceCursor: nil)

        XCTAssertEqual(tree.cursor, 150)
        XCTAssertEqual(tree.entries.count, 1)
        XCTAssertEqual(tree.entries[0].entryId, "e1")

        let expectedSnapshot = ISO8601DateFormatter().date(from: "2026-04-01T13:00:00Z")!
        let expectedUpdated = ISO8601DateFormatter().date(from: "2026-04-01T13:01:00Z")!
        XCTAssertEqual(tree.snapshotAt.timeIntervalSince1970, expectedSnapshot.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(tree.entries[0].updatedAt.timeIntervalSince1970, expectedUpdated.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_downloadFileContent_reportsProgressAndData() async throws {
        let payload = Data(repeating: 7, count: 65_536)

        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/files/entries/file-1/content")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "65536"]
                )!,
                payload
            )
        }

        let client = makeClient()
        let recorder = ProgressRecorder()

        let data = try await client.downloadFileContent(token: "token", entryId: "file-1") { progress in
            Task {
                await recorder.append(progress)
            }
        }

        let progressEvents = await recorder.snapshot()

        XCTAssertEqual(data.count, payload.count)
        XCTAssertEqual(progressEvents.last, 1.0)
        XCTAssertFalse(progressEvents.isEmpty)
    }

    func test_upsertEntry_sendsExpectedPayload() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/fs/entries")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream?.toData())
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["path"] as? String, "/docs")
            XCTAssertEqual(json["entryType"] as? String, "DIRECTORY")

            let responseBody = """
            {
              "entryId": "entry-1",
              "path": "/docs",
              "entryType": "DIRECTORY",
              "sizeBytes": 0,
              "checksum": null,
              "version": 1,
              "updatedAt": "2026-04-01T13:10:00Z",
              "deleted": false
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                responseBody
            )
        }

        let client = makeClient()
        let response = try await client.upsertEntry(
            token: "token",
            request: FsUpsertEntryRequest(
                entryId: "entry-1",
                path: "/docs",
                entryType: .directory,
                sizeBytes: 0,
                checksum: nil,
                deleted: false
            )
        )

        XCTAssertEqual(response.entryId, "entry-1")
        XCTAssertEqual(response.entryType, .directory)
    }

    func test_uploadSession_flowEncodesOffsetAndCompletes() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/files/upload-sessions"):
                let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream?.toData())
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["entryId"] as? String, "entry-2")

                let responseBody = """
                {
                  "sessionId": "session-1",
                  "entryId": "entry-2",
                  "uploadedBytes": 0,
                  "expectedSizeBytes": 4,
                  "status": "ACTIVE",
                  "updatedAt": "2026-04-01T14:00:00Z"
                }
                """.data(using: .utf8)!
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    responseBody
                )

            case ("PUT", "/files/upload-sessions/session-1/chunks"):
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "offset")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "0")
                let chunkBody = try XCTUnwrap(request.httpBody ?? request.httpBodyStream?.toData())
                XCTAssertEqual(chunkBody.count, 4)

                let responseBody = """
                {
                  "sessionId": "session-1",
                  "entryId": "entry-2",
                  "uploadedBytes": 4,
                  "expectedSizeBytes": 4,
                  "status": "ACTIVE",
                  "updatedAt": "2026-04-01T14:00:01Z"
                }
                """.data(using: .utf8)!
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    responseBody
                )

            case ("POST", "/files/upload-sessions/session-1/complete"):
                let responseBody = """
                {
                  "entryId": "entry-2",
                  "sizeBytes": 4,
                  "checksum": "abcd"
                }
                """.data(using: .utf8)!
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    responseBody
                )

            default:
                XCTFail("Unexpected request \(String(describing: request.httpMethod)) \(request.url?.path ?? "")")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
        }

        let client = makeClient()
        let session = try await client.createUploadSession(
            token: "token",
            request: FileUploadSessionCreateRequest(entryId: "entry-2")
        )
        XCTAssertEqual(session.sessionId, "session-1")

        _ = try await client.appendUploadChunk(
            token: "token",
            sessionId: session.sessionId,
            offset: 0,
            chunk: Data([0x01, 0x02, 0x03, 0x04])
        )

        let completion = try await client.completeUploadSession(token: "token", sessionId: session.sessionId)
        XCTAssertEqual(completion.entryId, "entry-2")
        XCTAssertEqual(completion.sizeBytes, 4)
    }

    func test_register_postsInvitationCodeAndDecodesResponse() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/auth/register")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = """
            {
              "username": "demo-jose",
              "quotaMb": 1024
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        let response = try await client.register(
            invitationCode: "NCDEMO1234567890",
            username: "demo-jose",
            password: "demo-passwd-2026"
        )

        XCTAssertEqual(response.username, "demo-jose")
        XCTAssertEqual(response.quotaMb, 1_024)
    }

    func test_register_invitationNotFound_throwsApiError() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            let body = """
            {
              "errorCode": "INVITATION_CODE_NOT_FOUND",
              "message": "Invitation code not found or already used",
              "timestamp": "2026-04-29T17:00:00Z"
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        do {
            _ = try await client.register(invitationCode: "BAD", username: "u", password: "p")
            XCTFail("Expected NodeAPIError.api")
        } catch let NodeAPIError.api(statusCode, errorCode, _) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(errorCode, "INVITATION_CODE_NOT_FOUND")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_fetchProfile_sendsBearerAndDecodesQuotaAndRole() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/auth/me")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-abc")
            let body = """
            {
              "username": "demo-jose",
              "quotaMb": 1024,
              "role": "END_USER"
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        let profile = try await client.fetchProfile(token: "token-abc")

        XCTAssertEqual(profile.username, "demo-jose")
        XCTAssertEqual(profile.quotaMb, 1_024)
        XCTAssertEqual(profile.role, "END_USER")
    }

    func test_patchEntry_sendsNewPathBodyAndDecodesUpdatedRecord() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/fs/entries/entry-canonical-1")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            // Body verification — debe ser {"newPath":"/demo/renamed.txt"}
            // Comprobado: el shape correcto vs `{"path":...}` que el backend rechazaría.
            let body = """
            {
              "entryId": "entry-canonical-1",
              "path": "/demo/renamed.txt",
              "entryType": "FILE",
              "sizeBytes": 20,
              "checksum": "bbee72e7",
              "version": 2,
              "updatedAt": "2026-04-29T17:30:00Z",
              "deleted": false
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        let updated = try await client.patchEntry(
            token: "t",
            entryId: "entry-canonical-1",
            request: FsPatchEntryRequest(newPath: "/demo/renamed.txt")
        )

        XCTAssertEqual(updated.entryId, "entry-canonical-1")
        XCTAssertEqual(updated.path, "/demo/renamed.txt")
        XCTAssertEqual(updated.version, 2)
    }

    func test_deleteEntry_sendsBearerAndAcceptsRecordResponse() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/fs/entries/entry-canonical-2")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            let body = """
            {
              "entryId": "entry-canonical-2",
              "path": "/demo/file.txt",
              "entryType": "FILE",
              "sizeBytes": 20,
              "checksum": null,
              "version": 3,
              "updatedAt": "2026-04-29T17:35:00Z",
              "deleted": true
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        try await client.deleteEntry(token: "t", entryId: "entry-canonical-2")
        // Si llega aquí, el endpoint funcionó (`deleteEntry` descarta el body).
    }

    func test_deleteEntry_notFound_throwsApiError() async throws {
        URLProtocolIntegrationStub.requestHandler = { request in
            let body = """
            {
              "errorCode": "FS_ENTRY_NOT_FOUND",
              "message": "entry not found",
              "timestamp": "2026-04-29T17:36:00Z"
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()
        do {
            try await client.deleteEntry(token: "t", entryId: "missing")
            XCTFail("Expected NodeAPIError.api")
        } catch let NodeAPIError.api(statusCode, errorCode, _) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(errorCode, "FS_ENTRY_NOT_FOUND")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> NodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolIntegrationStub.self]
        let session = URLSession(configuration: configuration)
        return NodeAPIClient(baseURL: URL(string: "http://localhost:8081")!, session: session)
    }
}

private actor ProgressRecorder {
    private var events: [Double] = []

    func append(_ value: Double) {
        events.append(value)
    }

    func snapshot() -> [Double] {
        events
    }
}

private extension InputStream {
    func toData() -> Data? {
        open()
        defer { close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while hasBytesAvailable {
            let read = self.read(buffer, maxLength: bufferSize)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }

        return data
    }
}

private final class URLProtocolIntegrationStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Bajo `swift test --parallel` (modo CI) los XCTestCases comparten
        // este `static var` y el `tearDown` de un test puede setearlo a
        // `nil` mientras otro test paralelo está mid-flight aquí.
        // Reportamos como `URLError(.unknown)` para que el test concreto
        // falle ordenadamente sin tumbar el bundle entero.
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
