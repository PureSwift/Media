/// A stretch of media time: where it starts and how long it lasts. It
/// includes its start and not its end.
public struct MediaTimeRange: Hashable, Sendable {

    public var start: MediaTime

    public var duration: MediaTime

    public init(start: MediaTime, duration: MediaTime) {
        self.start = start
        self.duration = duration
    }

    /// From `start` up to `end`.
    public init(start: MediaTime, end: MediaTime) {
        self.init(start: start, duration: end - start)
    }

    public static let zero = MediaTimeRange(start: .zero, duration: .zero)

    public static let invalid = MediaTimeRange(start: .invalid, duration: .invalid)

    /// From the start of time on, without end.
    public static let everything = MediaTimeRange(start: .negativeInfinity, duration: .positiveInfinity)

    /// The first time after the range; positive infinity for one without
    /// end, wherever it starts.
    public var end: MediaTime {
        duration == .positiveInfinity && start.isValid ? .positiveInfinity : start + duration
    }

    /// Whether its start is valid and its duration is valid and not
    /// negative.
    public var isValid: Bool {
        start.isValid && duration.isValid && !(duration.isNumeric && duration.value < 0) && duration != .negativeInfinity
    }

    /// Whether it holds no time.
    public var isEmpty: Bool { duration.isNumeric && duration.value == 0 }

    /// Whether `time` falls in it: at or after its start, and before its
    /// end.
    public func contains(_ time: MediaTime) -> Bool {
        guard isValid, time.isValid, !isEmpty else { return false }
        return time >= start && time < end
    }

    /// Whether all of `range` falls in it.
    public func contains(_ range: MediaTimeRange) -> Bool {
        guard isValid, range.isValid else { return false }
        return range.start >= start && range.end <= end
    }

    /// What the two have in common: an empty range at the later start when
    /// they don't meet.
    public func intersection(_ other: MediaTimeRange) -> MediaTimeRange {
        guard isValid, other.isValid else { return .invalid }
        let start = max(self.start, other.start)
        let end = min(self.end, other.end)
        return end > start ? MediaTimeRange(start: start, end: end) : MediaTimeRange(start: start, duration: .zero)
    }

    /// The smallest range holding both.
    public func union(_ other: MediaTimeRange) -> MediaTimeRange {
        guard isValid, other.isValid else { return .invalid }
        return MediaTimeRange(start: min(start, other.start), end: max(end, other.end))
    }
}

extension MediaTimeRange: CustomStringConvertible {

    public var description: String { "[\(start), \(end))" }
}
