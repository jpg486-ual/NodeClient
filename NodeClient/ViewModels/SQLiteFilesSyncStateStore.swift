import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteFilesSyncStateStore: FilesSyncStateStore {
    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        legacyUserDefaults: UserDefaults? = .standard,
        telemetryStore: SyncTelemetryStore? = nil
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.legacyUserDefaults = legacyUserDefaults
        self.telemetryStore = telemetryStore ?? UserDefaultsSyncTelemetryStore()
        openDatabase()
        ensureSchema()
        migrateLegacySnapshotsIfNeeded()
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }

        if let database {
            sqlite3_close(database)
        }
    }

    func readSnapshot(namespace: String) -> FilesSyncSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let database else {
            return nil
        }

        let effectiveNamespace = Self.sanitizedNamespace(namespace)
        guard let cursor = readCursor(database: database, namespace: effectiveNamespace) else {
            return nil
        }

        guard let entries = readEntries(database: database, namespace: effectiveNamespace) else {
            return nil
        }

        return FilesSyncSnapshot(cursor: cursor, entries: entries)
    }

    func writeSnapshot(_ snapshot: FilesSyncSnapshot, namespace: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let database else {
            return
        }

        let effectiveNamespace = Self.sanitizedNamespace(namespace)

        guard execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;") else {
            return
        }

        let persisted = upsertSnapshot(database: database, namespace: effectiveNamespace, cursor: snapshot.cursor)
            && clearEntries(database: database, namespace: effectiveNamespace)
            && insertEntries(database: database, namespace: effectiveNamespace, entries: snapshot.entries)

        _ = execute(database: database, sql: persisted ? "COMMIT;" : "ROLLBACK;")
    }

    func clearSnapshot(namespace: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let database else {
            return
        }

        let effectiveNamespace = Self.sanitizedNamespace(namespace)

        guard execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;") else {
            return
        }

        let cleared = clearEntries(database: database, namespace: effectiveNamespace)
            && clearSnapshotRow(database: database, namespace: effectiveNamespace)

        _ = execute(database: database, sql: cleared ? "COMMIT;" : "ROLLBACK;")
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let legacyUserDefaults: UserDefaults?
    private let telemetryStore: SyncTelemetryStore
    private let lock = NSLock()
    private var database: OpaquePointer?

    private var fallbackDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        // El directorio base lo resuelve `NodeClientAppGroups`
        // priorizando App Group container y cayendo a applicationSupport
        // si el entitlement falta.
        let directory = NodeClientAppGroups.resolvedDataDirectory(fileManager: fileManager)
        return directory.appendingPathComponent("files-sync-state.sqlite")
    }

    private static func sanitizedNamespace(_ namespace: String) -> String {
        let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "anonymous" : trimmed
    }

    private func openDatabase() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            database = nil
            return
        }

        var handle: OpaquePointer?
        if sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            database = handle
        } else {
            if let handle {
                sqlite3_close(handle)
            }
            database = nil
        }
    }

    private func ensureSchema() {
        guard let database else {
            return
        }

        let createSnapshotsTable = """
        CREATE TABLE IF NOT EXISTS sync_snapshots (
            namespace TEXT PRIMARY KEY,
            cursor INTEGER NOT NULL,
            persisted_at TEXT NOT NULL
        );
        """

        let createEntriesTable = """
        CREATE TABLE IF NOT EXISTS sync_entries (
            namespace TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            path TEXT NOT NULL,
            entry_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            checksum TEXT,
            version INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            deleted INTEGER NOT NULL,
            PRIMARY KEY (namespace, entry_id)
        );
        """

        let createIndex = """
        CREATE INDEX IF NOT EXISTS idx_sync_entries_namespace_path
        ON sync_entries(namespace, path);
        """

        _ = execute(database: database, sql: createSnapshotsTable)
        _ = execute(database: database, sql: createEntriesTable)
        _ = execute(database: database, sql: createIndex)
    }

    private func migrateLegacySnapshotsIfNeeded() {
        guard let legacyUserDefaults, let database else {
            return
        }

        let keyPrefix = UserDefaultsFilesSyncStateStore.snapshotKeyPrefix + "."
        let allKeys = legacyUserDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) }

        guard !allKeys.isEmpty else {
            return
        }

        guard execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;") else {
            return
        }

        var keysToRemove: [String] = []

        for key in allKeys.sorted() {
            let namespace = String(key.dropFirst(keyPrefix.count))
            guard !namespace.isEmpty else {
                continue
            }

            if readCursor(database: database, namespace: namespace) != nil {
                telemetryStore.increment(.migrationLegacySnapshotSkippedExisting)
                keysToRemove.append(key)
                continue
            }

            guard
                let data = legacyUserDefaults.data(forKey: key),
                let snapshot = decodeLegacySnapshot(from: data)
            else {
                telemetryStore.increment(.migrationLegacySnapshotInvalidPayload)
                continue
            }

            let migrated = upsertSnapshot(database: database, namespace: namespace, cursor: snapshot.cursor)
                && clearEntries(database: database, namespace: namespace)
                && insertEntries(database: database, namespace: namespace, entries: snapshot.entries)

            guard migrated else {
                _ = execute(database: database, sql: "ROLLBACK;")
                return
            }

            telemetryStore.increment(.migrationLegacySnapshotSuccess)
            keysToRemove.append(key)
        }

        guard execute(database: database, sql: "COMMIT;") else {
            _ = execute(database: database, sql: "ROLLBACK;")
            return
        }

        for key in keysToRemove {
            legacyUserDefaults.removeObject(forKey: key)
        }
    }

    private func decodeLegacySnapshot(from data: Data) -> FilesSyncSnapshot? {
        if let snapshot = try? fallbackDecoder.decode(FilesSyncSnapshot.self, from: data) {
            return snapshot
        }
        return try? JSONDecoder().decode(FilesSyncSnapshot.self, from: data)
    }

    private func execute(database: OpaquePointer, sql: String) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func upsertSnapshot(database: OpaquePointer, namespace: String, cursor: Int64) -> Bool {
        let sql = """
        INSERT INTO sync_snapshots(namespace, cursor, persisted_at)
        VALUES(?, ?, ?)
        ON CONFLICT(namespace) DO UPDATE SET cursor = excluded.cursor, persisted_at = excluded.persisted_at;
        """

        guard let statement = prepare(database: database, sql: sql) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        let now = Self.iso8601String(from: Date())

        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, cursor)
        sqlite3_bind_text(statement, 3, now, -1, SQLITE_TRANSIENT)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func readCursor(database: OpaquePointer, namespace: String) -> Int64? {
        let sql = "SELECT cursor FROM sync_snapshots WHERE namespace = ? LIMIT 1;"
        guard let statement = prepare(database: database, sql: sql) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_int64(statement, 0)
    }

    private func clearEntries(database: OpaquePointer, namespace: String) -> Bool {
        let sql = "DELETE FROM sync_entries WHERE namespace = ?;"
        guard let statement = prepare(database: database, sql: sql) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func clearSnapshotRow(database: OpaquePointer, namespace: String) -> Bool {
        let sql = "DELETE FROM sync_snapshots WHERE namespace = ?;"
        guard let statement = prepare(database: database, sql: sql) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func insertEntries(database: OpaquePointer, namespace: String, entries: [FilesSyncEntry]) -> Bool {
        let sql = """
        INSERT INTO sync_entries(
            namespace, entry_id, path, entry_type, size_bytes, checksum, version, updated_at, deleted
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        guard let statement = prepare(database: database, sql: sql) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        for entry in entries {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, entry.entryId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, entry.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, entry.entryType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 5, entry.sizeBytes)

            if let checksum = entry.checksum {
                sqlite3_bind_text(statement, 6, checksum, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 6)
            }

            sqlite3_bind_int64(statement, 7, entry.version)
            sqlite3_bind_text(statement, 8, Self.iso8601String(from: entry.updatedAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 9, entry.deleted ? 1 : 0)

            if sqlite3_step(statement) != SQLITE_DONE {
                return false
            }
        }

        return true
    }

    private func readEntries(database: OpaquePointer, namespace: String) -> [FilesSyncEntry]? {
        let sql = """
        SELECT entry_id, path, entry_type, size_bytes, checksum, version, updated_at, deleted
        FROM sync_entries
        WHERE namespace = ?
        ORDER BY path COLLATE NOCASE ASC;
        """

        guard let statement = prepare(database: database, sql: sql) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)

        var entries: [FilesSyncEntry] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let entryId = sqliteText(statement: statement, column: 0),
                let path = sqliteText(statement: statement, column: 1),
                let entryTypeRaw = sqliteText(statement: statement, column: 2),
                let entryType = FsEntryResponse.EntryType(rawValue: entryTypeRaw),
                let updatedAtText = sqliteText(statement: statement, column: 6),
                let updatedAt = Self.dateFromISO8601String(updatedAtText)
            else {
                return nil
            }

            let sizeBytes = sqlite3_column_int64(statement, 3)
            let checksum = sqliteText(statement: statement, column: 4)
            let version = sqlite3_column_int64(statement, 5)
            let deleted = sqlite3_column_int(statement, 7) == 1

            entries.append(
                FilesSyncEntry(
                    entryId: entryId,
                    path: path,
                    entryType: entryType,
                    sizeBytes: sizeBytes,
                    checksum: checksum,
                    version: version,
                    updatedAt: updatedAt,
                    deleted: deleted
                )
            )
        }

        return entries
    }

    private func prepare(database: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func sqliteText(statement: OpaquePointer, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    private static func dateFromISO8601String(_ value: String) -> Date? {
        iso8601Formatter.date(from: value) ?? legacyISO8601Formatter.date(from: value)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let legacyISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
