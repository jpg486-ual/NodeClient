import Foundation

enum SyncTelemetryEvent: String, CaseIterable {
    case syncIncrementalAttempt = "sync.incremental.attempt"
    case syncFullAttempt = "sync.full.attempt"
    case syncFallbackFullResync = "sync.full.fallback"
    case syncNetworkError = "sync.error.network"
    case syncApiError = "sync.error.api"
    case migrationLegacySnapshotSuccess = "migration.legacy.success"
    case migrationLegacySnapshotSkippedExisting = "migration.legacy.skipped_existing"
    case migrationLegacySnapshotInvalidPayload = "migration.legacy.invalid_payload"
    // Eventos sync background (BGTask iOS / NSBackgroundActivityScheduler macOS).
    case syncBackgroundAttempt = "sync.background.attempt"
    case syncBackgroundSuccess = "sync.background.success"
    case syncBackgroundSkippedNoSession = "sync.background.skipped.no_session"
    case syncBackgroundSkippedOffline = "sync.background.skipped.offline"
    case syncBackgroundErrorApi = "sync.background.error.api"
    case syncBackgroundErrorUnexpected = "sync.background.error.unexpected"
}

protocol SyncTelemetryStore {
    func increment(_ event: SyncTelemetryEvent)
    func value(for event: SyncTelemetryEvent) -> Int
    func snapshot() -> [SyncTelemetryEvent: Int]
    func resetAll()
}

struct UserDefaultsSyncTelemetryStore: SyncTelemetryStore {
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func increment(_ event: SyncTelemetryEvent) {
        let key = keyForEvent(event)
        let current = userDefaults.integer(forKey: key)
        userDefaults.set(current + 1, forKey: key)
    }

    func value(for event: SyncTelemetryEvent) -> Int {
        userDefaults.integer(forKey: keyForEvent(event))
    }

    func snapshot() -> [SyncTelemetryEvent: Int] {
        var values: [SyncTelemetryEvent: Int] = [:]
        for event in SyncTelemetryEvent.allCases {
            values[event] = value(for: event)
        }
        return values
    }

    func resetAll() {
        for event in SyncTelemetryEvent.allCases {
            userDefaults.removeObject(forKey: keyForEvent(event))
        }
    }

    private let userDefaults: UserDefaults

    private func keyForEvent(_ event: SyncTelemetryEvent) -> String {
        "node.sync.telemetry.\(event.rawValue)"
    }
}
