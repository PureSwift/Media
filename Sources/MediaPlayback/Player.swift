import AudioCodec
import MediaCore
import MediaFiles
import VideoCodec

/// Plays a media file or stream: reads it, decodes its video and audio, and
/// keeps them in step, following the sound when there's an output for it,
/// and the host's clock when not.
///
/// A player does its work when it's asked: call `update` for each frame
/// drawn, and it reads and decodes as far as it must, queues sound ahead,
/// and returns the picture to show then. A player is for one thread at a
/// time.
public final class Player {

    public enum State: Sendable, Equatable {
        case paused
        case playing
        /// Played to the end; `play` or `seek` starts again.
        case ended
    }

    public struct Options: Sendable {

        /// How far ahead sound is queued.
        public var audioAhead: MediaTime

        public init(audioAhead: MediaTime = MediaTime(value: 1, timescale: 2)) {
            self.audioAhead = audioAhead
        }
    }

    public let url: String

    public let options: Options

    /// How long it lasts; invalid when the file doesn't say.
    public let duration: MediaTime

    /// The track whose pictures it shows: the first video track it can
    /// decode.
    public let videoTrack: MediaReader.Track?

    /// The track it plays: the first audio track it can decode, when there's
    /// an output.
    public let audioTrack: MediaReader.Track?

    /// The PCM it sends to the output.
    public let audioFormat: AudioFormat?

    public private(set) var state: State = .paused

    /// The picture showing, from the last `update`.
    public private(set) var picture: SampleBuffer?

    private let reader: MediaReader

    private let videoDecoder: VideoDecoder?

    private let audioDecoder: AudioDecoder?

    private let output: AudioOutput?

    private let clock: HostClock

    /// Pictures decoded and not yet shown, in presentation order.
    private var pictures: [SampleBuffer] = []

    /// Where the sound queued ends: from the first PCM after a seek, its
    /// durations added up, as packets' own times are rounded by some files.
    private var audioEnd: MediaTime

    private var audioStarted = false

    /// Whether time follows the sound; not once it has run out.
    private var followsAudio: Bool

    /// Where the host's clock counts from, and when it started; nil while
    /// paused.
    private var position: MediaTime = .zero
    private var hostStart: MediaTime?

    /// Where playback started, at the last seek: nothing earlier plays.
    private var startTime: MediaTime = .zero

    private var endOfFile = false

    /// Opens a file or stream to play, paused at its start, with its sound
    /// sent to `audioOutput`, or none.
    public init(url: String, audioOutput: AudioOutput? = nil, clock: HostClock = SystemClock(), options: Options = Options()) throws {
        let reader = try MediaReader(url: url)
        var videoTrack: MediaReader.Track?
        var videoDecoder: VideoDecoder?
        var audioTrack: MediaReader.Track?
        var audioDecoder: AudioDecoder?
        var audioFormat: AudioFormat?
        for track in reader.tracks {
            switch track.format {
            case .video(let format) where videoDecoder == nil:
                // A track it can't decode is passed over.
                guard let decoder = try? VideoDecoder(format: format) else { continue }
                (videoTrack, videoDecoder) = (track, decoder)
            case .audio(let format) where audioDecoder == nil && audioOutput != nil:
                let pcm = AudioFormat.linearPCM(sampleRate: format.sampleRate, channelLayout: .standard(channelCount: format.channelCount),
                                                layout: .float32)
                let options = AudioDecoder.Options(layout: .float32, sampleRate: pcm.sampleRate, channelLayout: pcm.channelLayout)
                guard let decoder = try? AudioDecoder(format: format, options: options) else { continue }
                (audioTrack, audioDecoder, audioFormat) = (track, decoder, pcm)
            default:
                continue
            }
        }
        try reader.select(tracks: Set([videoTrack?.id, audioTrack?.id].compactMap { $0 }))
        if let audioFormat, let audioOutput {
            try audioOutput.open(audioFormat)
            audioOutput.isPaused = true
        }
        self.url = url
        self.options = options
        self.reader = reader
        self.duration = reader.duration
        self.videoTrack = videoTrack
        self.videoDecoder = videoDecoder
        self.audioTrack = audioTrack
        self.audioDecoder = audioDecoder
        self.audioFormat = audioFormat
        self.output = audioDecoder != nil ? audioOutput : nil
        self.clock = clock
        self.audioEnd = .zero
        self.followsAudio = audioDecoder != nil
    }

    /// Where playback is: the sound's played, or the host clock's time
    /// since `play`.
    public var currentTime: MediaTime {
        if followsAudio, let output {
            return max(startTime, audioEnd - output.queuedDuration)
        }
        guard let hostStart else { return position }
        return position + (clock.now - hostStart)
    }

    public func play() {
        guard state != .playing else { return }
        if state == .ended {
            seek(to: .zero)
        }
        position = currentTime
        hostStart = clock.now
        output?.isPaused = false
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        position = currentTime
        hostStart = nil
        output?.isPaused = true
        state = .paused
    }

    /// Moves to `time`: the next `update` shows the picture then, and sound
    /// plays from there.
    public func seek(to time: MediaTime) {
        let target = max(time, .zero)
        try? reader.seek(to: target)
        videoDecoder?.reset()
        audioDecoder?.reset()
        output?.flush()
        pictures = []
        picture = nil
        endOfFile = false
        startTime = target
        audioEnd = target
        audioStarted = false
        followsAudio = audioDecoder != nil
        position = target
        if state == .playing {
            hostStart = clock.now
        } else {
            hostStart = nil
            if state == .ended { state = .paused }
        }
    }

    /// Reads and decodes as far as playback needs, queues sound ahead, and
    /// returns the picture to show now: the latest at or before it, or the
    /// first, before any.
    @discardableResult
    public func update() throws -> SampleBuffer? {
        while !endOfFile, needsMore() {
            try readSample()
        }
        let now = currentTime
        while let next = pictures.first, picture == nil || next.presentationTime <= now {
            picture = pictures.removeFirst()
        }
        if followsAudio, let output, endOfFile, output.queuedDuration <= .zero {
            // The sound has run out: the host clock goes on from there.
            position = now
            hostStart = state == .playing ? clock.now : nil
            followsAudio = false
        }
        if state == .playing, endOfFile, pictures.isEmpty, !followsAudio {
            let pictureEnd = picture.map { $0.presentationTime + ($0.duration.isNumeric ? $0.duration : .zero) } ?? .zero
            if now >= pictureEnd {
                pause()
                state = .ended
            }
        }
        return picture
    }

    /// Whether there's no picture after now yet, or too little sound queued.
    private func needsMore() -> Bool {
        let now = currentTime
        if videoDecoder != nil, (pictures.last.map { $0.presentationTime <= now } ?? true) { return true }
        if audioDecoder != nil, audioEnd - now < options.audioAhead { return true }
        return false
    }

    private func readSample() throws {
        guard let (track, sample) = try reader.nextSample() else {
            endOfFile = true
            if let videoDecoder { add(try videoDecoder.finish()) }
            if let audioDecoder { try enqueue(audioDecoder.finish()) }
            return
        }
        if track == videoTrack?.id, let videoDecoder {
            add(try videoDecoder.decode(sample))
        } else if track == audioTrack?.id, let audioDecoder {
            try enqueue(audioDecoder.decode(sample))
        }
    }

    /// Pictures decoded, less those already passed.
    private func add(_ decoded: [SampleBuffer]) {
        pictures += decoded
        let now = currentTime
        while pictures.count > 1, pictures[1].presentationTime <= now {
            pictures.removeFirst()
        }
    }

    /// PCM to the output, cut to start no earlier than playback.
    private func enqueue(_ decoded: [SampleBuffer]) throws {
        guard let output, let audioFormat, let bytesPerFrame = audioFormat.bytesPerFrame else { return }
        for var pcm in decoded {
            let end = pcm.presentationTime + pcm.duration
            guard end > startTime else { continue }
            if pcm.presentationTime < startTime, let data = pcm.data {
                let cut = min(Int(((startTime - pcm.presentationTime).seconds * audioFormat.sampleRate).rounded()), pcm.sampleCount)
                guard cut < pcm.sampleCount else { continue }
                let rate = Int32(audioFormat.sampleRate.rounded())
                pcm.content = .data(data[cut * bytesPerFrame..<data.count])
                pcm.sampleCount -= cut
                pcm.timing.presentationTime = pcm.presentationTime + MediaTime(value: Int64(cut), timescale: rate)
                pcm.timing.duration = MediaTime(value: Int64(pcm.sampleCount), timescale: rate)
            }
            if !audioStarted {
                audioStarted = true
                let gap = Int(((pcm.presentationTime - startTime).seconds * audioFormat.sampleRate).rounded())
                if gap > 0 {
                    // The sound starts after playback does: silence until then,
                    // to keep in step.
                    let rate = Int32(audioFormat.sampleRate.rounded())
                    try output.enqueue(SampleBuffer(
                        content: .data(BlockBuffer(bytes: [UInt8](repeating: 0, count: gap * bytesPerFrame))),
                        format: .audio(audioFormat),
                        timing: SampleTiming(presentationTime: startTime, duration: MediaTime(value: Int64(gap), timescale: rate)),
                        sampleCount: gap, flags: .sync
                    ))
                    audioEnd = startTime + MediaTime(value: Int64(gap), timescale: rate)
                } else {
                    audioEnd = pcm.presentationTime
                }
            }
            try output.enqueue(pcm)
            audioEnd = audioEnd + pcm.duration
        }
    }
}
