/// What a track or a sample holds.
public enum MediaType: Hashable, Sendable {
    case video
    case audio
    /// Subtitles and captions.
    case text
    /// Timed metadata.
    case metadata
    /// Anything else, by its four-character code.
    case other(FourCharacterCode)
}

/// A four-character code, as media files and codecs name things: `avc1`,
/// `mp4a`. Its characters are the code's bytes, first to last.
public struct FourCharacterCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {

    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The code of four ASCII characters; spaces pad a shorter string, and
    /// characters past four are left out.
    public init(_ characters: String) {
        var bytes = Array(characters.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        rawValue = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The four characters; bytes that aren't printable ASCII as `?`.
    public var description: String {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: rawValue >> (24 - 8 * $0)) }
        return String(decoding: bytes.map { (0x20..<0x7F).contains($0) ? $0 : 0x3F }, as: UTF8.self)
    }
}

/// The codec a sample's data is in, by the four-character code MP4 files
/// give it.
public struct CodecType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {

    public var rawValue: FourCharacterCode

    public init(rawValue: FourCharacterCode) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: FourCharacterCode(value))
    }

    public var description: String { rawValue.description }

    // MARK: Video

    /// H.264, with its parameter sets in the format's `avcC`.
    public static let h264: CodecType = "avc1"
    /// H.265, with its parameter sets in the format's `hvcC`.
    public static let hevc: CodecType = "hvc1"
    public static let av1: CodecType = "av01"
    public static let vp8: CodecType = "vp08"
    public static let vp9: CodecType = "vp09"
    public static let mpeg4Video: CodecType = "mp4v"
    public static let jpeg: CodecType = "jpeg"
    public static let proRes422: CodecType = "apcn"

    // MARK: Audio

    /// AAC, with its AudioSpecificConfig in the format's magic cookie.
    public static let aac: CodecType = "mp4a"
    public static let opus: CodecType = "Opus"
    public static let mp3: CodecType = ".mp3"
    public static let flac: CodecType = "fLaC"
    public static let vorbis: CodecType = "vorb"
    public static let ac3: CodecType = "ac-3"
    public static let eac3: CodecType = "ec-3"
    public static let alac: CodecType = "alac"
    /// Uncompressed samples, as the audio format describes them.
    public static let linearPCM: CodecType = "lpcm"
}
