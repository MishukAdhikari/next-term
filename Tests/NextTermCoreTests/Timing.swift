import Foundation

/// Times for the tests that guard against work growing out of proportion: a quadratic loop, a list read again on
/// every call. A wall-clock bound alone fails on a busy machine (a shared CI runner, a laptop building beside the
/// tests) while the code is as fast as ever, so these measure what is the code's own:
/// - `best(of:)`: the fastest of a few runs. A run the scheduler interrupted only ever comes out slower, so the
///   fastest is the one nearest the work's own cost.
/// - `ratio(_:to:)`: the work against a baseline of known-proportionate work on the same input, on the same machine,
///   at the same moment, so a machine that is slower or busier slows both alike and the ratio stays.
enum Timing {
    static func best(of runs: Int = 5, _ work: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock()
        var fastest = Duration.seconds(Int64.max)
        for _ in 0..<max(1, runs) {
            let took = try clock.measure { try autoreleasepool { try work() } }
            fastest = min(fastest, took)
        }
        return fastest
    }

    /// How many times the baseline's time the work takes, each the best of `runs`, runs taking turns so a slow spell
    /// falls on both. A baseline measured as nothing (under the clock's resolution) counts as a microsecond.
    static func ratio(of runs: Int = 5, _ work: () throws -> Void, to baseline: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var fastestWork = Duration.seconds(Int64.max)
        var fastestBaseline = Duration.seconds(Int64.max)
        for _ in 0..<max(1, runs) {
            fastestBaseline = min(fastestBaseline, try clock.measure { try autoreleasepool { try baseline() } })
            fastestWork = min(fastestWork, try clock.measure { try autoreleasepool { try work() } })
        }
        return seconds(fastestWork) / max(seconds(fastestBaseline), 1e-6)
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
