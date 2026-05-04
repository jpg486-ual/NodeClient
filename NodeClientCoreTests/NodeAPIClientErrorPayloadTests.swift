import Foundation
@testable import NodeClientCore
import XCTest

final class NodeAPIClientErrorPayloadTests: XCTestCase {
    override func tearDown() {
        URLProtocolErrorPayloadStub.requestHandler = nil
        super.tearDown()
    }

    func test_fetchTree_whenApiErrorPayloadIsReturned_throwsStructuredApiError() async {
        URLProtocolErrorPayloadStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/fs/tree")
            let body = """
            {
              "errorCode":"FS_TREE_INVALID_REQUEST",
              "message":"sinceCursor must be greater than or equal to zero",
              "timestamp":"2026-04-01T00:00:00Z"
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let client = makeClient()

        do {
            _ = try await client.fetchTree(token: "token", sinceCursor: -1)
            XCTFail("Expected NodeAPIError.api")
        } catch let error as NodeAPIError {
            XCTAssertEqual(
                error,
                .api(
                    statusCode: 400,
                    errorCode: "FS_TREE_INVALID_REQUEST",
                    message: "sinceCursor must be greater than or equal to zero"
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> NodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolErrorPayloadStub.self]
        let session = URLSession(configuration: configuration)
        return NodeAPIClient(baseURL: URL(string: "http://localhost:8081")!, session: session)
    }
}

private final class URLProtocolErrorPayloadStub: URLProtocol {
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
        // Antes el guard usaba `fatalError`, que tumbaba todo el bundle
        // de tests con `error: fatalError`. Ahora reportamos el fallo
        // como `URLError(.unknown)` y el test concreto falla
        // ordenadamente sin arrastrar al resto.
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
