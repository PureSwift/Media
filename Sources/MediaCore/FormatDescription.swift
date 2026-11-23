/// What a track's samples are: their media type and codec, and what a
/// decoder or a renderer needs to know of them.
public enum FormatDescription: Hashable, Sendable {
    case video(VideoFormat)
    case audio(AudioFormat)
    /// Text, metadata and other samples, by their codec alone.
    case other(MediaType, CodecType)

    public var mediaType: MediaType {
        switch self {
        case .video: .video
        case .audio: .audio
        case .other(let type, _): type
        }
    }

    public var codec: CodecType {
        switch self {
        case .video(let format): format.codec
        case .audio(let format): format.codec
        case .other(_, let codec): codec
        }
    }
}

// MARK: - Video

/// Coded video: its codec, its size, and how its pixels show.
public struct VideoFormat: Hashable, Sendable {

    public var codec: CodecType

    /// The coded picture's size in pixels.
    public var width: Int

    public var height: Int

    /// How wide a pixel is against how tall, as a ratio: 1:1 for square
    /// pixels.
    public var pixelAspectRatio: (horizontal: Int, vertical: Int)

    public var color: ColorInfo

    /// The codec's configuration record, which a decoder starts from: an
    /// `avcC` for H.264, an `hvcC` for H.265, an `av1C`, a `vpcC`. Empty
    /// when the stream carries its own.
    public var configuration: [UInt8]

    public init(
        codec: CodecType,
        width: Int,
        height: Int,
        pixelAspectRatio: (horizontal: Int, vertical: Int) = (1, 1),
        color: ColorInfo = ColorInfo(),
        configuration: [UInt8] = []
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.pixelAspectRatio = pixelAspectRatio
        self.color = color
        self.configuration = configuration
    }

    /// The size the picture shows at, in square pixels: its width scaled by
    /// the pixel aspect ratio.
    public var displaySize: (width: Int, height: Int) {
        let (horizontal, vertical) = pixelAspectRatio
        guard horizontal > 0, vertical > 0, horizontal != vertical else { return (width, height) }
        return ((width * horizontal + vertical / 2) / vertical, height)
    }

    public static func == (lhs: VideoFormat, rhs: VideoFormat) -> Bool {
        lhs.codec == rhs.codec && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.pixelAspectRatio == rhs.pixelAspectRatio && lhs.color == rhs.color && lhs.configuration == rhs.configuration
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(codec)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(pixelAspectRatio.horizontal)
        hasher.combine(pixelAspectRatio.vertical)
        hasher.combine(color)
        hasher.combine(configuration)
    }
}

// MARK: - Audio

/// Audio: its codec, rate and channels, and for uncompressed audio how its
/// samples are laid out.
public struct AudioFormat: Hashable, Sendable {

    public var codec: CodecType

    /// Frames a second: one sample for each channel.
    public var sampleRate: Double

    public var channelLayout: ChannelLayout

    /// For linear PCM, how its samples are stored; nil for coded audio.
    public var pcm: PCMLayout?

    /// Frames in each packet: 1 for PCM, 1024 for AAC; 0 when packets
    /// vary.
    public var framesPerPacket: Int

    /// The codec's magic cookie, which a decoder starts from: AAC's
    /// AudioSpecificConfig, an `esds` box, Opus's header. Empty when the
    /// codec needs none.
    public var magicCookie: [UInt8]

    public init(
        codec: CodecType,
        sampleRate: Double,
        channelLayout: ChannelLayout,
        pcm: PCMLayout? = nil,
        framesPerPacket: Int = 0,
        magicCookie: [UInt8] = []
    ) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
        self.pcm = pcm
        self.framesPerPacket = framesPerPacket
        self.magicCookie = magicCookie
    }

    /// Linear PCM in `layout`, a frame to a packet.
    public static func linearPCM(sampleRate: Double, channelLayout: ChannelLayout, layout: PCMLayout) -> AudioFormat {
        AudioFormat(codec: .linearPCM, sampleRate: sampleRate, channelLayout: channelLayout, pcm: layout, framesPerPacket: 1)
    }

    public var channelCount: Int { channelLayout.channels.count }

    /// For linear PCM, the bytes a frame of every channel takes.
    public var bytesPerFrame: Int? {
        guard let pcm else { return nil }
        return pcm.bytesPerSample * channelCount
    }
}

/// How linear PCM's samples are stored.
public struct PCMLayout: Hashable, Sendable {

    public enum SampleType: Hashable, Sendable {
        case signedInteger
        case unsignedInteger
        case float
    }

    public var sampleType: SampleType

    public var bitsPerSample: Int

    /// Whether a frame's channels follow each other, or each channel's
    /// samples are a plane of their own.
    public var isInterleaved: Bool

    public var isBigEndian: Bool

    public init(sampleType: SampleType, bitsPerSample: Int, isInterleaved: Bool = true, isBigEndian: Bool = false) {
        self.sampleType = sampleType
        self.bitsPerSample = bitsPerSample
        self.isInterleaved = isInterleaved
        self.isBigEndian = isBigEndian
    }

    public var bytesPerSample: Int { (bitsPerSample + 7) / 8 }

    /// 16-bit integers, interleaved, little-endian.
    public static let int16 = PCMLayout(sampleType: .signedInteger, bitsPerSample: 16)

    /// 32-bit floats, interleaved, little-endian.
    public static let float32 = PCMLayout(sampleType: .float, bitsPerSample: 32)
}

/// The speakers a frame's channels are for, in order.
public struct ChannelLayout: Hashable, Sendable {

    public enum Channel: Hashable, Sendable {
        case frontLeft, frontRight, frontCenter, lowFrequency
        case backLeft, backRight, backCenter
        case sideLeft, sideRight
        case frontLeftOfCenter, frontRightOfCenter
        case topCenter, topFrontLeft, topFrontCenter, topFrontRight, topBackLeft, topBackCenter, topBackRight
        /// A channel for no speaker in particular, by its index.
        case discrete(Int)
    }

    public var channels: [Channel]

    public init(_ channels: [Channel]) {
        self.channels = channels
    }

    /// `count` channels for no speakers in particular.
    public static func discrete(_ count: Int) -> ChannelLayout {
        ChannelLayout((0..<max(count, 0)).map(Channel.discrete))
    }

    /// The usual layout for `count` channels: mono, stereo, and so on to
    /// 7.1, as decoders order them; discrete channels past that.
    public static func standard(channelCount count: Int) -> ChannelLayout {
        switch count {
        case 1: .mono
        case 2: .stereo
        case 3: ChannelLayout([.frontLeft, .frontRight, .frontCenter])
        case 4: ChannelLayout([.frontLeft, .frontRight, .backLeft, .backRight])
        case 5: ChannelLayout([.frontLeft, .frontRight, .frontCenter, .backLeft, .backRight])
        case 6: .surround5_1
        case 8: .surround7_1
        default: .discrete(count)
        }
    }

    public static let mono = ChannelLayout([.frontCenter])
    public static let stereo = ChannelLayout([.frontLeft, .frontRight])
    public static let surround5_1 = ChannelLayout([.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight])
    public static let surround7_1 = ChannelLayout([
        .frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight, .sideLeft, .sideRight,
    ])
}
