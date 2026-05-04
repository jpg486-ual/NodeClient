import Foundation

enum NodeAPIError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case notFound
    case server(Int)
    case api(statusCode: Int, errorCode: String, message: String?)
    case transport(String)
}

/// Subprotocolo mínimo que necesita `SessionRefreshCoordinator`. Existe
/// para que el coordinator (y sus tests) no dependan de la superficie
/// completa de `NodeAPIClientProtocol` — un spy de tests solo necesita
/// implementar `refresh(token:)`.
protocol SessionRefreshAPIClient {
    func refresh(token: String) async throws -> AuthLoginResponse
}

extension SessionRefreshAPIClient {
    func refresh(token: String) async throws -> AuthLoginResponse {
        throw NodeAPIError.transport("refresh not implemented")
    }
}

protocol NodeAPIClientProtocol: SessionRefreshAPIClient {
    func login(username: String, password: String) async throws -> AuthLoginResponse
    func register(invitationCode: String, username: String, password: String) async throws -> AuthRegisterResponse
    func fetchProfile(token: String) async throws -> AuthProfileResponse
    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse
    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data
    /// Download streaming verdadero. Devuelve un `AsyncThrowingStream<UInt8>`
    /// que emite los bytes wire conforme llegan (sin acumular en RAM) más el
    /// `expectedLength` declarado por `Content-Length` cuando esté disponible
    /// (0 si el server no lo emite). Permite que el caller los procese
    /// chunk-a-chunk (e.g. `Nce3StreamingCipher.decryptStreaming`) o los
    /// vuelque a disco directamente. Implementación default delega al método
    /// monolítico para compat con mocks que no lo overrideen.
    func downloadFileContentBytes(token: String, entryId: String) async throws -> (stream: AsyncThrowingStream<UInt8, Error>, expectedLength: Int64)
    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse
    func patchEntry(token: String, entryId: String, request: FsPatchEntryRequest) async throws -> FsEntryResponse
    func deleteEntry(token: String, entryId: String) async throws
    /// Borra un directorio completo + descendientes en 1 roundtrip.
    /// Usar en lugar de `deleteEntry` cuando el target es una carpeta — el
    /// endpoint single deja huérfanos los hijos.
    func deleteSubtree(token: String, path: String) async throws -> FsDeleteSubtreeResponse
    /// Mueve/renombra un directorio completo + descendientes en 1
    /// roundtrip atómico. Usar en lugar de `patchEntry` cuando el target es
    /// una carpeta — el endpoint single sólo cambia el padre y descuelga los
    /// hijos del path antiguo.
    func moveSubtree(token: String, fromPath: String, toPath: String) async throws -> FsMoveSubtreeResponse
    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse
    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse
    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse
    func logout(token: String) async throws
}

extension NodeAPIClientProtocol {
    func register(invitationCode: String, username: String, password: String) async throws -> AuthRegisterResponse {
        throw NodeAPIError.transport("register not implemented")
    }

    func fetchProfile(token: String) async throws -> AuthProfileResponse {
        throw NodeAPIError.transport("fetchProfile not implemented")
    }

    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        throw NodeAPIError.transport("upsertEntry not implemented")
    }

    /// Si el adapter concrete no overridea
    /// `downloadFileContentBytes`, delegamos al método monolítico y
    /// reemitimos los bytes a través de un `AsyncThrowingStream`. Útil para
    /// mocks que solo implementan `downloadFileContent`. Pierde el beneficio
    /// streaming (la `Data` ya está cargada antes de emitir) — los callers
    /// que sí lo override (e.g. `NodeAPIClient` real con `URLSession.bytes`)
    /// mantienen RAM peak constante.
    func downloadFileContentBytes(
        token: String,
        entryId: String
    ) async throws -> (stream: AsyncThrowingStream<UInt8, Error>, expectedLength: Int64) {
        let data = try await downloadFileContent(
            token: token,
            entryId: entryId,
            onProgress: { _ in }
        )
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
        return (stream, Int64(data.count))
    }

    func patchEntry(token: String, entryId: String, request: FsPatchEntryRequest) async throws -> FsEntryResponse {
        throw NodeAPIError.transport("patchEntry not implemented")
    }

    func deleteEntry(token: String, entryId: String) async throws {
        throw NodeAPIError.transport("deleteEntry not implemented")
    }

    func deleteSubtree(token: String, path: String) async throws -> FsDeleteSubtreeResponse {
        throw NodeAPIError.transport("deleteSubtree not implemented")
    }

    func moveSubtree(token: String, fromPath: String, toPath: String) async throws -> FsMoveSubtreeResponse {
        throw NodeAPIError.transport("moveSubtree not implemented")
    }

    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse {
        throw NodeAPIError.transport("createUploadSession not implemented")
    }

    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse {
        throw NodeAPIError.transport("appendUploadChunk not implemented")
    }

    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        throw NodeAPIError.transport("completeUploadSession not implemented")
    }
}

struct NodeAPIClient: NodeAPIClientProtocol {
    /// URL canónica de fallback cuando el operador no ha configurado
    /// `baseURL` en el SessionStore. Coincide con el puerto por defecto
    /// del backend Node en setup local de desarrollo.
    static let defaultLocalBaseURL = URL(string: "http://localhost:8081")!

    /// Centraliza el patrón `URL(string: stored) ?? defaultLocalBaseURL`
    /// para evitar duplicación en composition root y view-models.
    static func resolveBaseURL(from string: String?) -> URL {
        guard let string, let url = URL(string: string) else {
            return defaultLocalBaseURL
        }
        return url
    }

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private static let iso8601WithFractionalSeconds = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let iso8601WithoutFractionalSeconds = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = try? Self.iso8601WithFractionalSeconds.parse(value) {
                return date
            }

            if let date = try? Self.iso8601WithoutFractionalSeconds.parse(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected date string to be ISO8601-formatted."
            )
        }
        decoder = jsonDecoder

        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        encoder = jsonEncoder
    }

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        guard let endpoint = URL(string: "/auth/login", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(AuthLoginRequest(username: username, password: password))

        return try await execute(request, as: AuthLoginResponse.self)
    }

    func register(invitationCode: String, username: String, password: String) async throws -> AuthRegisterResponse {
        guard let endpoint = URL(string: "/auth/register", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            AuthRegisterRequest(
                invitationCode: invitationCode,
                username: username,
                password: password
            )
        )

        return try await execute(request, as: AuthRegisterResponse.self)
    }

    func refresh(token: String) async throws -> AuthLoginResponse {
        guard let endpoint = URL(string: "/auth/refresh", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await execute(request, as: AuthLoginResponse.self)
    }

    func fetchProfile(token: String) async throws -> AuthProfileResponse {
        guard let endpoint = URL(string: "/auth/me", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await execute(request, as: AuthProfileResponse.self)
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        guard var components = URLComponents(
            url: URL(string: "/fs/tree", relativeTo: baseURL) ?? baseURL,
            resolvingAgainstBaseURL: true
        ) else {
            throw NodeAPIError.invalidURL
        }

        if let sinceCursor {
            components.queryItems = [
                URLQueryItem(name: "sinceCursor", value: String(sinceCursor))
            ]
        }

        guard let url = components.url else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await execute(request, as: FsTreeResponse.self)
    }

    func upsertEntry(token: String, request: FsUpsertEntryRequest) async throws -> FsEntryResponse {
        guard let endpoint = URL(string: "/fs/entries", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        return try await execute(urlRequest, as: FsEntryResponse.self)
    }

    func patchEntry(token: String, entryId: String, request: FsPatchEntryRequest) async throws -> FsEntryResponse {
        let escapedId = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        guard let endpoint = URL(string: "/fs/entries/\(escapedId)", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "PATCH"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        return try await execute(urlRequest, as: FsEntryResponse.self)
    }

    func deleteEntry(token: String, entryId: String) async throws {
        let escapedId = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        guard let endpoint = URL(string: "/fs/entries/\(escapedId)", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // Backend devuelve 200 con el record actualizado (deleted=true);
        // descartamos el body, sólo nos interesa la confirmación HTTP.
        _ = try await execute(urlRequest, as: FsEntryResponse.self)
    }

    func deleteSubtree(token: String, path: String) async throws -> FsDeleteSubtreeResponse {
        guard let endpoint = URL(string: "/fs/entries/delete-subtree", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(FsDeleteSubtreeRequest(path: path))

        return try await execute(urlRequest, as: FsDeleteSubtreeResponse.self)
    }

    func moveSubtree(token: String, fromPath: String, toPath: String) async throws -> FsMoveSubtreeResponse {
        guard let endpoint = URL(string: "/fs/entries/move-subtree", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(FsMoveSubtreeRequest(fromPath: fromPath, toPath: toPath))

        return try await execute(urlRequest, as: FsMoveSubtreeResponse.self)
    }

    func createUploadSession(token: String, request: FileUploadSessionCreateRequest) async throws -> FileUploadSessionResponse {
        guard let endpoint = URL(string: "/files/upload-sessions", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        return try await execute(urlRequest, as: FileUploadSessionResponse.self)
    }

    func appendUploadChunk(token: String, sessionId: String, offset: Int64, chunk: Data) async throws -> FileUploadSessionResponse {
        guard var components = URLComponents(
            url: URL(string: "/files/upload-sessions/\(sessionId)/chunks", relativeTo: baseURL) ?? baseURL,
            resolvingAgainstBaseURL: true
        ) else {
            throw NodeAPIError.invalidURL
        }

        components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]

        guard let url = components.url else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = chunk

        return try await execute(urlRequest, as: FileUploadSessionResponse.self)
    }

    func completeUploadSession(token: String, sessionId: String) async throws -> FileContentUploadResponse {
        guard let endpoint = URL(string: "/files/upload-sessions/\(sessionId)/complete", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await execute(urlRequest, as: FileContentUploadResponse.self)
    }

    func downloadFileContent(token: String, entryId: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let endpoint = URL(string: "/files/entries/\(entryId)/content", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse

        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw NodeAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NodeAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            let expectedLength = max(httpResponse.expectedContentLength, 0)
            var receivedLength: Int64 = 0
            var data = Data()

            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    receivedLength += 1

                    if expectedLength > 0, receivedLength.isMultiple(of: 32_768) {
                        let progress = min(1.0, Double(receivedLength) / Double(expectedLength))
                        onProgress(progress)
                    }
                }
            } catch {
                if Self.isCancellation(error) {
                    throw CancellationError()
                }
                throw NodeAPIError.transport(error.localizedDescription)
            }

            onProgress(1.0)
            return data

        case 401:
            throw NodeAPIError.unauthorized

        case 404:
            throw NodeAPIError.notFound

        default:
            var errorData = Data()
            do {
                for try await byte in bytes {
                    errorData.append(byte)
                }
            } catch {
                if Self.isCancellation(error) {
                    throw CancellationError()
                }
                throw NodeAPIError.transport(error.localizedDescription)
            }
            throw mapError(statusCode: httpResponse.statusCode, data: errorData)
        }
    }

    /// Download streaming exponiendo `URLSession.AsyncBytes`
    /// envuelto en un `AsyncThrowingStream<UInt8>` portable. Maneja status
    /// codes y cancellation idénticamente a `downloadFileContent` legacy,
    /// pero NO acumula bytes en `Data` — el caller los recibe conforme
    /// llegan del socket TCP.
    func downloadFileContentBytes(
        token: String,
        entryId: String
    ) async throws -> (stream: AsyncThrowingStream<UInt8, Error>, expectedLength: Int64) {
        guard let endpoint = URL(string: "/files/entries/\(entryId)/content", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let urlBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (urlBytes, response) = try await session.bytes(for: request)
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw NodeAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NodeAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            let expectedLength = max(httpResponse.expectedContentLength, 0)
            let stream = AsyncThrowingStream<UInt8, Error> { continuation in
                let task = Task {
                    do {
                        for try await byte in urlBytes {
                            try Task.checkCancellation()
                            continuation.yield(byte)
                        }
                        continuation.finish()
                    } catch {
                        if Self.isCancellation(error) {
                            continuation.finish(throwing: CancellationError())
                        } else {
                            continuation.finish(throwing: NodeAPIError.transport(error.localizedDescription))
                        }
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
            return (stream, expectedLength)

        case 401:
            throw NodeAPIError.unauthorized

        case 404:
            throw NodeAPIError.notFound

        default:
            var errorData = Data()
            do {
                for try await byte in urlBytes {
                    errorData.append(byte)
                }
            } catch {
                if Self.isCancellation(error) {
                    throw CancellationError()
                }
                throw NodeAPIError.transport(error.localizedDescription)
            }
            throw mapError(statusCode: httpResponse.statusCode, data: errorData)
        }
    }

    func logout(token: String) async throws {
        guard let endpoint = URL(string: "/auth/logout", relativeTo: baseURL) else {
            throw NodeAPIError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NodeAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NodeAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return

        case 401:
            throw NodeAPIError.unauthorized

        case 404:
            // El backend devuelve payload estructurado en 404
            // para algunos endpoints (FS_ENTRY_NOT_FOUND, INVITATION_CODE_NOT_FOUND,
            // FILE_UPLOAD_ENTRY_NOT_FOUND, etc.). Si parseamos el errorCode lo
            // exponemos como `.api(404, ...)`; si el body es vacío/no-estándar,
            // mantenemos el legacy `.notFound` para compatibilidad.
            throw mapErrorOrNotFound(statusCode: 404, data: data)

        default:
            throw mapError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    private func execute<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // SwiftUI cancela el Task del `.refreshable` cuando la View se
            // invalida durante el gesto; URLSession devuelve NSURLErrorCancelled.
            // Propagar como CancellationError para que el caller distinga
            // cancelación legítima de un fallo de transporte real.
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw NodeAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NodeAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return try decoder.decode(type, from: data)

        case 401:
            throw NodeAPIError.unauthorized

        case 404:
            // Payload estructurado en 404 → `.api(404, errorCode)`;
            // body vacío → fallback `.notFound` (compatibilidad).
            throw mapErrorOrNotFound(statusCode: 404, data: data)

        default:
            throw mapError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    /// Prefiere el `errorCode` estructurado del backend
    /// cuando existe, fallback al `.notFound` legacy si no.
    private func mapErrorOrNotFound(statusCode: Int, data: Data) -> NodeAPIError {
        if !data.isEmpty,
           let payload = try? decoder.decode(NodeAPIErrorPayload.self, from: data),
           let errorCode = payload.errorCode,
           !errorCode.isEmpty {
            return .api(statusCode: statusCode, errorCode: errorCode, message: payload.message)
        }
        return .notFound
    }

    private func mapError(statusCode: Int, data: Data) -> NodeAPIError {
        guard !data.isEmpty else {
            return .server(statusCode)
        }

        if let payload = try? decoder.decode(NodeAPIErrorPayload.self, from: data),
           let errorCode = payload.errorCode,
           !errorCode.isEmpty {
            return .api(statusCode: statusCode, errorCode: errorCode, message: payload.message)
        }

        return .server(statusCode)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private struct NodeAPIErrorPayload: Decodable {
    let errorCode: String?
    let message: String?
    let timestamp: Date?
}
