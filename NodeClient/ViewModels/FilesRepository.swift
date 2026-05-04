import Foundation

struct SyncRetryPolicy {
    let maxAttempts: Int
    let initialDelayNanoseconds: UInt64
    let multiplier: Double

    static let `default` = Self(
        maxAttempts: 3,
        initialDelayNanoseconds: 200_000_000,
        multiplier: 2.0
    )

    func delayBeforeRetry(retryIndex: Int) -> UInt64 {
        guard retryIndex > 0 else {
            return initialDelayNanoseconds
        }

        let delay = Double(initialDelayNanoseconds) * pow(multiplier, Double(retryIndex))
        return UInt64(delay)
    }
}

protocol FilesRepositoryProtocol {
    func readCachedFiles(namespace: String) -> [FileItem]
    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem]
}

struct DefaultFilesRepository: FilesRepositoryProtocol {
    typealias Sleeper = (UInt64) async -> Void

    init(
        apiClient: NodeAPIClientProtocol,
        syncStateStore: FilesSyncStateStore,
        telemetryStore: SyncTelemetryStore,
        retryPolicy: SyncRetryPolicy = .default,
        sleeper: @escaping Sleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.apiClient = apiClient
        self.syncStateStore = syncStateStore
        self.telemetryStore = telemetryStore
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
    }

    func readCachedFiles(namespace: String) -> [FileItem] {
        guard let snapshot = syncStateStore.readSnapshot(namespace: namespace) else {
            return []
        }
        return Self.makeFileItems(from: snapshot.entries.map(\.asResponse))
    }

    func synchronizeFiles(token: String, namespace: String) async throws -> [FileItem] {
        let snapshot = syncStateStore.readSnapshot(namespace: namespace)

        do {
            do {
                if snapshot != nil {
                    telemetryStore.increment(.syncIncrementalAttempt)
                } else {
                    telemetryStore.increment(.syncFullAttempt)
                }

                // Cursor con overlap de 1 ms: el backend usa
                // `findByUsernameAndUpdatedAtAfter` con `>` estricto. En
                // escenarios delete+re-upload donde ambos timestamps caen
                // en el mismo millisegundo (o el cursor previo coincide
                // con el millisegundo de un cambio nuevo), el delta puede
                // perder el cambio. Restar 1 ms al cursor enviado fuerza
                // un solape mínimo. El `mergeEntries` es idempotente
                // (indexa por `entryId`) — el overlap no introduce
                // duplicados ni inconsistencias.
                let probedCursor: Int64? = snapshot.map { max(0, $0.cursor - 1) }
                let tree = try await executeWithRetry {
                    try await apiClient.fetchTree(token: token, sinceCursor: probedCursor)
                }

                let mergedEntries = Self.mergeEntries(base: snapshot?.entries.map(\.asResponse) ?? [], delta: tree.entries)
                let cursor = max(snapshot?.cursor ?? 0, tree.cursor)

                syncStateStore.writeSnapshot(
                    FilesSyncSnapshot(
                        cursor: cursor,
                        entries: mergedEntries.map(FilesSyncEntry.init(response:))
                    ),
                    namespace: namespace
                )
                return Self.makeFileItems(from: mergedEntries)
            } catch let error as NodeAPIError {
                if Self.shouldFallbackToFullResync(error), snapshot != nil {
                    telemetryStore.increment(.syncFallbackFullResync)
                    telemetryStore.increment(.syncFullAttempt)

                    let fullTree = try await executeWithRetry {
                        try await apiClient.fetchTree(token: token, sinceCursor: nil)
                    }
                    let fullEntries = Self.mergeEntries(base: [], delta: fullTree.entries)
                    syncStateStore.writeSnapshot(
                        FilesSyncSnapshot(
                            cursor: fullTree.cursor,
                            entries: fullEntries.map(FilesSyncEntry.init(response:))
                        ),
                        namespace: namespace
                    )
                    return Self.makeFileItems(from: fullEntries)
                }
                throw error
            }
        } catch let error as NodeAPIError {
            if case .transport = error {
                telemetryStore.increment(.syncNetworkError)
            } else {
                telemetryStore.increment(.syncApiError)
            }
            throw error
        } catch {
            telemetryStore.increment(.syncApiError)
            throw error
        }
    }

    private let apiClient: NodeAPIClientProtocol
    private let syncStateStore: FilesSyncStateStore
    private let telemetryStore: SyncTelemetryStore
    private let retryPolicy: SyncRetryPolicy
    private let sleeper: Sleeper

    private func executeWithRetry<Response>(
        operation: () async throws -> Response
    ) async throws -> Response {
        var attempt = 0

        while true {
            do {
                return try await operation()
            } catch let error as NodeAPIError {
                let canRetry = Self.isTransient(error)
                    && attempt + 1 < retryPolicy.maxAttempts

                guard canRetry else {
                    throw error
                }

                let delay = retryPolicy.delayBeforeRetry(retryIndex: attempt)
                await sleeper(delay)
                attempt += 1
            }
        }
    }

    private static func isTransient(_ error: NodeAPIError) -> Bool {
        switch error {
        case .transport:
            return true

        case .server(let statusCode):
            return statusCode == 429 || statusCode >= 500

        case .api(let statusCode, _, _):
            return statusCode == 429 || statusCode >= 500

        default:
            return false
        }
    }

    private static func shouldFallbackToFullResync(_ error: NodeAPIError) -> Bool {
        switch error {
        case .server(let statusCode):
            return statusCode == 400

        case let .api(statusCode, errorCode, _):
            return statusCode == 400
                || errorCode == "FS_TREE_INVALID_REQUEST"
                || errorCode == "SYNC_INVALID_SINCE"

        default:
            return false
        }
    }

    private static func mergeEntries(base: [FsEntryResponse], delta: [FsEntryResponse]) -> [FsEntryResponse] {
        var byId: [String: FsEntryResponse] = Dictionary(uniqueKeysWithValues: base.map { ($0.entryId, $0) })

        for entry in delta {
            if entry.deleted {
                byId.removeValue(forKey: entry.entryId)
            } else {
                byId[entry.entryId] = entry
            }
        }

        return byId.values.sorted { left, right in
            if left.entryType != right.entryType {
                return left.entryType == .directory
            }
            return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
        }
    }

    private static func makeFileItems(from entries: [FsEntryResponse]) -> [FileItem] {
        entries
            .filter { !$0.deleted }
            .sorted { left, right in
                if left.entryType != right.entryType {
                    return left.entryType == .directory
                }
                return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
            }
            .map { entry in
                FileItem(
                    id: entry.entryId,
                    name: entry.displayName,
                    path: entry.path,
                    detail: entry.detailText,
                    systemImage: entry.systemImage,
                    isFolder: entry.isFolder,
                    isShared: false,
                    isOffline: false,
                    sizeBytes: entry.sizeBytes,
                    updatedAt: entry.updatedAt,
                    version: entry.version
                )
            }
    }
}
