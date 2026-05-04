import Foundation
@testable import NodeClientCore
import XCTest

final class NodeAPIClientLogoutTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func test_logout_sendsPostWithBearerAuthorization() async throws {
        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/auth/logout")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let client = makeClient()
        try await client.logout(token: "token-123")
    }

    func test_logout_whenUnauthorized_throwsUnauthorized() async {
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let client = makeClient()

        do {
            try await client.logout(token: "expired-token")
            XCTFail("Expected NodeAPIError.unauthorized")
        } catch let error as NodeAPIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_logout_whenNotFound_throwsNotFound() async {
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let client = makeClient()

        do {
            try await client.logout(token: "token-404")
            XCTFail("Expected NodeAPIError.notFound")
        } catch let error as NodeAPIError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_logout_whenServerError_throwsServerStatusCode() async {
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let client = makeClient()

        do {
            try await client.logout(token: "token-503")
            XCTFail("Expected NodeAPIError.server")
        } catch let error as NodeAPIError {
            XCTAssertEqual(error, .server(503))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_logout_whenTransportFails_throwsTransport() async {
        URLProtocolStub.requestHandler = { _ in
            throw NSError(domain: "NodeClientTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "offline"])
        }

        let client = makeClient()

        do {
            try await client.logout(token: "token-offline")
            XCTFail("Expected NodeAPIError.transport")
        } catch let error as NodeAPIError {
            guard case .transport(let detail) = error else {
                XCTFail("Unexpected NodeAPIError: \(error)")
                return
            }
            XCTAssertTrue(detail.contains("offline"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> NodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return NodeAPIClient(baseURL: URL(string: "http://localhost:8081")!, session: session)
    }
}

private final class URLProtocolStub: URLProtocol {
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
