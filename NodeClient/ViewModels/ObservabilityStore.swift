import Foundation

enum LogLevel: String, Codable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ level: Self) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}

struct DiagnosticTrace: Codable, Equatable {
    let timestamp: Date
    let level: LogLevel
    let category: String
    let event: String
    let message: String?
    let metadata: [String: String]
}

protocol ObservabilityStore {
    func log(
        level: LogLevel,
        category: String,
        event: String,
        message: String?,
        metadata: [String: String]
    )
    func incrementCounter(_ name: String)
    func recordDuration(_ name: String, milliseconds: Double)
    func counter(named name: String) -> Int
    func latestDuration(named name: String) -> Double?
    func recentTraces(limit: Int, minimumLevel: LogLevel?) -> [DiagnosticTrace]
    func reset()
}

struct UserDefaultsObservabilityStore: ObservabilityStore {
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func log(
        level: LogLevel,
        category: String,
        event: String,
        message: String?,
        metadata: [String: String] = [:]
    ) {
        let sanitized = Self.sanitize(metadata)
        let trace = DiagnosticTrace(
            timestamp: Date(),
            level: level,
            category: category,
            event: event,
            message: message,
            metadata: sanitized
        )

        var traces = loadTraces()
        traces.append(trace)
        if traces.count > Self.maxTraceCount {
            traces = Array(traces.suffix(Self.maxTraceCount))
        }
        storeTraces(traces)
    }

    func incrementCounter(_ name: String) {
        let key = Self.counterPrefix + name
        let current = userDefaults.integer(forKey: key)
        userDefaults.set(current + 1, forKey: key)
    }

    func recordDuration(_ name: String, milliseconds: Double) {
        let key = Self.durationPrefix + name
        userDefaults.set(milliseconds, forKey: key)
    }

    func counter(named name: String) -> Int {
        userDefaults.integer(forKey: Self.counterPrefix + name)
    }

    func latestDuration(named name: String) -> Double? {
        let key = Self.durationPrefix + name
        guard userDefaults.object(forKey: key) != nil else {
            return nil
        }
        return userDefaults.double(forKey: key)
    }

    func recentTraces(limit: Int = 20, minimumLevel: LogLevel? = nil) -> [DiagnosticTrace] {
        let traces = loadTraces()
        let filtered = traces.filter { trace in
            guard let minimumLevel else {
                return true
            }
            return trace.level >= minimumLevel
        }
        return Array(filtered.suffix(max(0, limit)))
    }

    func reset() {
        userDefaults.removeObject(forKey: Self.tracesKey)

        let dictionary = userDefaults.dictionaryRepresentation()
        for key in dictionary.keys where key.hasPrefix(Self.counterPrefix) || key.hasPrefix(Self.durationPrefix) {
            userDefaults.removeObject(forKey: key)
        }
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let tracesKey = "node.observability.traces"
    private static let counterPrefix = "node.observability.counter."
    private static let durationPrefix = "node.observability.duration."
    private static let maxTraceCount = 200

    private func loadTraces() -> [DiagnosticTrace] {
        guard let data = userDefaults.data(forKey: Self.tracesKey),
              let traces = try? decoder.decode([DiagnosticTrace].self, from: data) else {
            return []
        }
        return traces
    }

    private func storeTraces(_ traces: [DiagnosticTrace]) {
        if let data = try? encoder.encode(traces) {
            userDefaults.set(data, forKey: Self.tracesKey)
        }
    }

    private static func sanitize(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        for (key, value) in metadata {
            let keyLower = key.lowercased()
            if isSensitiveKey(keyLower) || isSensitiveValue(value) {
                result[key] = "[REDACTED]"
            } else {
                result[key] = value
            }
        }

        return result
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let terms = ["token", "password", "authorization", "secret", "credential", "session"]
        return terms.contains { key.contains($0) }
    }

    private static func isSensitiveValue(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("bearer ") || lowered.contains("password")
    }
}
