import Foundation

public struct LegacyDuration: Sendable, Comparable, CustomStringConvertible {
    public let seconds: Double
    public static func seconds<T: BinaryInteger>(_ value: T) -> Self { Self(seconds: Double(value)) }
    public static func seconds(_ value: Double) -> Self { Self(seconds: value) }
    public static func milliseconds<T: BinaryInteger>(_ value: T) -> Self { Self(seconds: Double(value) / 1000) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.seconds < rhs.seconds }
    public var description: String { "\(seconds) seconds" }
}
public enum LegacyClock {
    public struct Instant: Sendable, Comparable {
        let uptime: Double
        public func duration(to other: Self) -> LegacyDuration { LegacyDuration(seconds: other.uptime - uptime) }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.uptime < rhs.uptime }
        public static func + (lhs: Self, rhs: LegacyDuration) -> Self { Self(uptime: lhs.uptime + rhs.seconds) }
    }
    public static var now: Instant { Instant(uptime: ProcessInfo.processInfo.systemUptime) }
}
extension LegacyClock.Instant {
    public static var now: Self { LegacyClock.now }
}
extension Task where Success == Never, Failure == Never {
    public static func legacySleep(for duration: LegacyDuration) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(max(0, min(duration.seconds, Double(UInt64.max) / 1e9)) * 1e9))
    }
}
extension URL {
    public var legacyPercentEncodedPath: String { URLComponents(url: self, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? path }
}
