import CSDL3
import MediaCore
import MediaPlayback

/// Plays a player's sound through SDL3: an audio stream bound to a playback
/// device, which SDL converts and mixes for it.
///
/// It takes interleaved, little-endian PCM: 8-bit unsigned, 16- or 32-bit
/// signed, or 32-bit float. What's queued is the stream's; the device's own
/// buffer, a few milliseconds, isn't counted.
public final class SDLAudioOutput: AudioOutput {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// SDL failed, with its message.
        case sdl(String)
        /// PCM SDL's streams don't take.
        case unsupportedFormat(String)
        /// Sound was queued before the output was opened.
        case notOpen

        public var description: String {
            switch self {
            case .sdl(let message): "SDL: \(message)"
            case .unsupportedFormat(let format): "SDL can't play \(format)"
            case .notOpen: "the output isn't open"
            }
        }

        static var current: Error {
            .sdl(SDL_GetError().map { String(cString: $0) } ?? "unknown error")
        }
    }

    /// SDL's default playback device, which follows the system's choice.
    public static let defaultDevice = SDL_AudioDeviceID(0xFFFF_FFFF)

    /// The device it plays on.
    public let device: SDL_AudioDeviceID

    /// The PCM it was opened for.
    public private(set) var format: AudioFormat?

    private var stream: OpaquePointer?

    private var bytesPerFrame = 0

    private var paused = true

    /// An output on `device`, SDL's default playback device unless told,
    /// once opened. SDL's audio is started here, and stopped when it goes.
    public init(device: SDL_AudioDeviceID = SDLAudioOutput.defaultDevice) throws {
        guard SDL_InitSubSystem(SDL_InitFlags(SDL_INIT_AUDIO)) else { throw Error.current }
        self.device = device
    }

    deinit {
        if let stream { SDL_DestroyAudioStream(stream) }
        SDL_QuitSubSystem(SDL_InitFlags(SDL_INIT_AUDIO))
    }

    public func open(_ format: AudioFormat) throws {
        guard format.codec == .linearPCM, let pcm = format.pcm, pcm.isInterleaved, !pcm.isBigEndian else {
            throw Error.unsupportedFormat(String(describing: format.pcm))
        }
        let sdlFormat: SDL_AudioFormat
        switch (pcm.sampleType, pcm.bitsPerSample) {
        case (.unsignedInteger, 8): sdlFormat = SDL_AUDIO_U8
        case (.signedInteger, 16): sdlFormat = SDL_AUDIO_S16LE
        case (.signedInteger, 32): sdlFormat = SDL_AUDIO_S32LE
        case (.float, 32): sdlFormat = SDL_AUDIO_F32LE
        default: throw Error.unsupportedFormat("\(pcm.bitsPerSample)-bit \(pcm.sampleType)")
        }
        if let stream {
            SDL_DestroyAudioStream(stream)
            self.stream = nil
        }
        var spec = SDL_AudioSpec(format: sdlFormat, channels: Int32(format.channelCount), freq: Int32(format.sampleRate.rounded()))
        // The device starts paused.
        guard let stream = SDL_OpenAudioDeviceStream(device, &spec, nil, nil) else { throw Error.current }
        self.stream = stream
        self.format = format
        self.bytesPerFrame = format.bytesPerFrame ?? 0
        self.paused = true
    }

    public func enqueue(_ pcm: SampleBuffer) throws {
        guard let stream else { throw Error.notOpen }
        guard let data = pcm.data, !data.isEmpty else { return }
        let put = data.withUnsafeBytes { SDL_PutAudioStreamData(stream, $0.baseAddress, Int32(clamping: $0.count)) }
        guard put else { throw Error.current }
    }

    public var queuedDuration: MediaTime {
        guard let stream, let format, bytesPerFrame > 0 else { return .zero }
        let bytes = max(Int(SDL_GetAudioStreamQueued(stream)), 0)
        return MediaTime(value: Int64(bytes / bytesPerFrame), timescale: Int32(format.sampleRate.rounded()))
    }

    public var isPaused: Bool {
        get { paused }
        set {
            paused = newValue
            guard let stream else { return }
            if newValue {
                SDL_PauseAudioStreamDevice(stream)
            } else {
                SDL_ResumeAudioStreamDevice(stream)
            }
        }
    }

    public func flush() {
        guard let stream else { return }
        SDL_ClearAudioStream(stream)
    }
}
