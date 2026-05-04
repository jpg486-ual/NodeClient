//  TDD para el hint de reconstrucción durante
//  download. Si el `downloadProgress` permanece en 0 durante más de
//  `recoveryHintDelayNanos`, se muestra un mensaje "Reconstruyendo..."
//  para evitar que el usuario crea que la app se ha colgado durante
//  la fase de recovery del backend (discovery + fetch fragments +
//  Reed-Solomon decode antes de empezar a stream).

import Foundation
@testable import NodeClientCore
import XCTest

@MainActor
final class FilesViewModelDownloadRecoveryHintTests: XCTestCase {
    // Polling con timeout: en CI macOS los runners son lentos y la cadena
    // Task<download> → MainActor → scheduleRecoveryHint → Task.sleep →
    // MainActor.run puede sobrepasar holgadamente cualquier `Task.sleep`
    // fijo. Polling cada 10 ms hasta `timeoutMs` mantiene el test rápido
    // localmente y resiliente bajo carga CI.
    private static let pollIntervalNs: UInt64 = 10_000_000
    private static let pollTimeoutMs: Int = 3_000

    private func waitForHintToAppear(_ vm: FilesViewModel) async {
        let start = Date()
        while Date().timeIntervalSince(start) * 1_000 < Double(Self.pollTimeoutMs) {
            if vm.downloadHintMessage != nil { return }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNs)
        }
    }

    private func waitForHintToClear(_ vm: FilesViewModel) async {
        let start = Date()
        while Date().timeIntervalSince(start) * 1_000 < Double(Self.pollTimeoutMs) {
            if vm.downloadHintMessage == nil { return }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNs)
        }
    }

    func test_recoveryHint_appearsAfterDelay_whenProgressStaysAtZero() async {
        let api = SlowMockAPIClient(initialDelayNanos: 0)
        api.releaseProgressHook = nil  // jamás llega progreso > 0
        let viewModel = makeViewModel(apiClient: api, hintDelayNanos: 50_000_000)
        let item = makeFileItem(id: "f1", name: "report-large.pdf")

        // Lanzar el download en background — bloqueará hasta que la API
        // libere los datos. Mientras tanto el hint debe aparecer.
        let downloadTask = Task { await viewModel.downloadFile(item) }

        await waitForHintToAppear(viewModel)

        XCTAssertEqual(viewModel.downloadHintFileName, "report-large.pdf")
        XCTAssertEqual(
            viewModel.downloadHintMessage,
            "Reconstruyendo «report-large.pdf» desde fragmentos del nodo. Esto puede tardar unos segundos."
        )

        // Liberar la "descarga" mock para que la tarea complete.
        api.releaseDownload(with: Data("done".utf8))
        await downloadTask.value

        // Tras completar, el hint queda limpio.
        XCTAssertNil(viewModel.downloadHintMessage)
        XCTAssertNil(viewModel.downloadHintFileName)
    }

    func test_recoveryHint_isClearedWhenFirstProgressArrives() async {
        let api = SlowMockAPIClient(initialDelayNanos: 0)
        let viewModel = makeViewModel(apiClient: api, hintDelayNanos: 50_000_000)
        let item = makeFileItem(id: "f2", name: "movie.mp4")

        let downloadTask = Task { await viewModel.downloadFile(item) }

        await waitForHintToAppear(viewModel)
        XCTAssertNotNil(viewModel.downloadHintMessage, "El hint debería estar visible tras el delay")

        // Simular llegada del primer chunk (progress=0.05).
        api.emitProgress(0.05)
        await waitForHintToClear(viewModel)

        XCTAssertNil(viewModel.downloadHintMessage, "El hint debería desaparecer al llegar progreso > 0")

        api.releaseDownload(with: Data("done".utf8))
        await downloadTask.value
    }

    func test_recoveryHint_doesNotAppear_ifDownloadCompletesQuickly() async {
        // Caso archivo pequeño / fragmentos locales: el download completa
        // antes del delay del hint. El hint nunca debería emerger.
        let api = SlowMockAPIClient(initialDelayNanos: 0)
        let viewModel = makeViewModel(apiClient: api, hintDelayNanos: 500_000_000)
        let item = makeFileItem(id: "f3", name: "tiny.txt")

        let downloadTask = Task { await viewModel.downloadFile(item) }

        // Liberar inmediatamente (antes del delay 500ms).
        try? await Task.sleep(nanoseconds: 30_000_000)
        api.emitProgress(0.5)
        api.releaseDownload(with: Data("ok".utf8))
        await downloadTask.value

        XCTAssertNil(viewModel.downloadHintMessage,
                     "Para archivos rápidos el hint no debería aparecer.")
    }

    func test_recoveryHint_clearsOnError() async {
        let api = SlowMockAPIClient(initialDelayNanos: 0)
        let viewModel = makeViewModel(apiClient: api, hintDelayNanos: 50_000_000)
        let item = makeFileItem(id: "f4", name: "fails.pdf")

        let downloadTask = Task { await viewModel.downloadFile(item) }

        await waitForHintToAppear(viewModel)
        XCTAssertNotNil(viewModel.downloadHintMessage)

        api.failDownload(with: NodeAPIError.transport("network down"))
        await downloadTask.value

        XCTAssertNil(viewModel.downloadHintMessage,
                     "Tras error el hint debe limpiarse.")
    }

    // MARK: - Helpers

    private func makeViewModel(
        apiClient: NodeAPIClientProtocol,
        hintDelayNanos: UInt64
    ) -> FilesViewModel {
        FilesViewModel(
            apiClient: apiClient,
            sessionTokenProvider: { "token" },
            syncStateStore: InMemoryDownloadHintSyncStore(),
            syncNamespaceProvider: { "tester" },
            filesRepository: StubDownloadHintRepository(),
            recoveryHintDelayNanos: hintDelayNanos,
            fileSaver: { _, _ in URL(fileURLWithPath: "/tmp/test.bin") }
        )
    }

    private func makeFileItem(id: String, name: String) -> FileItem {
        FileItem(
            id: id,
            name: name,
            path: "/\(name)",
            detail: "1 KB",
            systemImage: "doc",
            isFolder: false,
            isShared: false,
            isOffline: false
        )
    }
}

// MARK: - Mock con control manual del lifecycle de download

private final class SlowMockAPIClient: NodeAPIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var progressCallback: (@Sendable (Double) -> Void)?
    private(set) var initialDelayNanos: UInt64
    var releaseProgressHook: (() -> Void)?

    init(initialDelayNanos: UInt64) {
        self.initialDelayNanos = initialDelayNanos
    }

    func emitProgress(_ progress: Double) {
        lock.lock()
        let cb = progressCallback
        lock.unlock()
        cb?(progress)
    }

    func releaseDownload(with data: Data) {
        lock.lock()
        let c = continuation
        continuation = nil
        progressCallback = nil
        lock.unlock()
        c?.resume(returning: data)
    }

    func failDownload(with error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        progressCallback = nil
        lock.unlock()
        c?.resume(throwing: error)
    }

    func login(username: String, password: String) async throws -> AuthLoginResponse {
        AuthLoginResponse(token: "", username: username, quotaMb: 0, expiresAt: Date())
    }

    func fetchTree(token: String, sinceCursor: Int64?) async throws -> FsTreeResponse {
        FsTreeResponse(username: "", cursor: 0, snapshotAt: Date(), entries: [])
    }

    func downloadFileContent(
        token: String,
        entryId: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        if initialDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: initialDelayNanos)
        }
        return try await withCheckedThrowingContinuation { c in
            lock.lock()
            continuation = c
            progressCallback = onProgress
            lock.unlock()
        }
    }

    func logout(token: String) async throws {}
}

private final class InMemoryDownloadHintSyncStore: FilesSyncStateStore {
    func readSnapshot(namespace: String) -> FilesSyncSnapshot? { nil }
    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {}
    func clearSnapshot(namespace: String) {}
}

private struct StubDownloadHintRepository: FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem] { [] }
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] { [] }
}
