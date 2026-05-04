@testable import NodeClientCore
import XCTest

final class ObservabilityStoreTests: XCTestCase {
    func test_log_redactsSensitiveMetadata() {
        let defaults = makeDefaults()
        let store = UserDefaultsObservabilityStore(userDefaults: defaults)

        store.log(
            level: .error,
            category: "auth",
            event: "login.failed",
            message: "failed",
            metadata: [
                "token": "abc.def.ghi",
                "authorization": "Bearer token-value",
                "password": "secret",
                "host": "localhost"
            ]
        )

        let traces = store.recentTraces(limit: 5, minimumLevel: nil)
        XCTAssertEqual(traces.count, 1)
        let metadata = traces[0].metadata
        XCTAssertEqual(metadata["token"], "[REDACTED]")
        XCTAssertEqual(metadata["authorization"], "[REDACTED]")
        XCTAssertEqual(metadata["password"], "[REDACTED]")
        XCTAssertEqual(metadata["host"], "localhost")
    }

    func test_metricsStore_recordsDurationsAndCounters() {
        let defaults = makeDefaults()
        let store = UserDefaultsObservabilityStore(userDefaults: defaults)

        store.recordDuration("login.latency.ms", milliseconds: 87.5)
        store.incrementCounter("download.success")
        store.incrementCounter("download.success")

        XCTAssertEqual(store.latestDuration(named: "login.latency.ms"), 87.5)
        XCTAssertEqual(store.counter(named: "download.success"), 2)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ObservabilityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
