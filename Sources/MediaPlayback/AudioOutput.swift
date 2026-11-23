import MediaCore

/// Where a player sends its sound: a device that plays queued PCM, such as
/// SDL3's audio stream.
///
/// The player follows the sound: what's played is what's queued, less what
/// is still waiting, so an output reports its queue as it plays.
public protocol AudioOutput: AnyObject {

    /// Gets ready to play linear PCM in `format`, paused.
    func open(_ format: AudioFormat) throws

    /// Queues PCM, in the format opened with, to play after what's queued.
    func enqueue(_ pcm: SampleBuffer) throws

    /// How long the PCM queued and not yet played lasts.
    var queuedDuration: MediaTime { get }

    /// Whether it holds the queue instead of playing.
    var isPaused: Bool { get set }

    /// Drops the PCM queued, as after a seek.
    func flush()
}
