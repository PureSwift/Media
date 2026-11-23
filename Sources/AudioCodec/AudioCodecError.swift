import CFFmpeg
import MediaCore

/// Why an audio codec couldn't be made or couldn't go on.
public enum AudioCodecError: Error, Equatable, Sendable, CustomStringConvertible {
    /// libavcodec has no decoder, or no encoder, for the codec.
    case unsupportedCodec(CodecType)
    /// PCM laid out in a way libswresample doesn't take: 24-bit, or
    /// big-endian, samples.
    case unsupportedLayout(String)
    /// Audio to encode that isn't linear PCM, or whose bytes aren't whole
    /// frames.
    case mismatchedAudio
    /// A sample with no bytes to decode.
    case noData
    /// libavcodec or libswresample failed: its error code and description.
    case codec(code: Int32, message: String)

    public var description: String {
        switch self {
        case .unsupportedCodec(let codec): "no codec for \(codec)"
        case .unsupportedLayout(let layout): "unsupported PCM layout \(layout)"
        case .mismatchedAudio: "the audio isn't whole frames of linear PCM"
        case .noData: "the sample has no bytes"
        case .codec(let code, let message): "libavcodec error \(code): \(message)"
        }
    }

    /// libavcodec's error, described.
    static func ffmpeg(_ code: Int32) -> AudioCodecError {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return .codec(code: code, message: message)
    }
}

/// Throws libavcodec's error for a negative result.
@discardableResult
func check(_ result: Int32) throws -> Int32 {
    guard result >= 0 else { throw AudioCodecError.ffmpeg(result) }
    return result
}
