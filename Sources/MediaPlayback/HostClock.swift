import MediaCore

/// The time a player measures playback by when there's no sound to follow.
public protocol HostClock: AnyObject {

    /// The time now, from any origin, moving forward.
    var now: MediaTime { get }
}

/// The system's monotonic clock, in nanoseconds.
public final class SystemClock: HostClock {

    private let origin = ContinuousClock.now

    public init() {}

    public var now: MediaTime {
        let elapsed = ContinuousClock.now - origin
        let (seconds, attoseconds) = elapsed.components
        return MediaTime(value: seconds * 1_000_000_000 + attoseconds / 1_000_000_000, timescale: 1_000_000_000)
    }
}
