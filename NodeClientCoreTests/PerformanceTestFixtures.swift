//  Generadores deterministas para PerformanceTests.
//
//  Seed fija + RandomNumberGenerator reproducible para
//  garantizar baselines comparables cross-machine y cross-run.

import Foundation
@testable import NodeClientCore

enum PerformanceTestFixtures {
    /// Genera un FilesSyncSnapshot con `entryCount` entries deterministas.
    /// Usado para baselines de SQLite write/read.
    static func makeSyncSnapshot(entryCount: Int) -> FilesSyncSnapshot {
        var rng = SeededRandomNumberGenerator(seed: 0xC0DE_F00D)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<entryCount).map { idx -> FilesSyncEntry in
            let typeFlag = Int.random(in: 0...9, using: &rng)
            let entryType: FsEntryResponse.EntryType = typeFlag < 8 ? .file : .directory
            let sizeBytes = Int64.random(in: 0...10_000_000, using: &rng)
            let version = Int64.random(in: 1...500, using: &rng)
            let updatedAt = baseDate.addingTimeInterval(TimeInterval(idx))
            return FilesSyncEntry(
                entryId: String(format: "perf-entry-%08d", idx),
                path: "/perf/snapshot/folder-\(idx % 100)/item-\(idx).bin",
                entryType: entryType,
                sizeBytes: sizeBytes,
                checksum: entryType == .file
                    ? String(format: "sha256-%064x", idx)
                    : nil,
                version: version,
                updatedAt: updatedAt,
                deleted: idx.isMultiple(of: 50)
            )
        }
        return FilesSyncSnapshot(cursor: Int64(entryCount), entries: entries)
    }
}

/// Linear-congruential PRNG semillado para reproducibilidad cross-run.
/// No criptográfico — sólo para fixtures de tests.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        // Numerical Recipes LCG, Knuth multiplier.
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
