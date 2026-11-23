import CFFmpeg
import MediaCore

/// Why a codec couldn't be made or couldn't go on.
public enum VideoCodecError: Error, Equatable, Sendable, CustomStringConvertible {
    /// libavcodec has no decoder, or no encoder, for the codec.
    case unsupportedCodec(CodecType)
    /// Pictures in a pixel format the codec or this library doesn't handle,
    /// by FFmpeg's name for it.
    case unsupportedPixelFormat(String)
    /// A picture whose size or format isn't the encoder's.
    case mismatchedPicture
    /// A sample with no bytes to decode.
    case noData
    /// libavcodec failed: its error code and description.
    case codec(code: Int32, message: String)

    public var description: String {
        switch self {
        case .unsupportedCodec(let codec): "no codec for \(codec)"
        case .unsupportedPixelFormat(let name): "unsupported pixel format \(name)"
        case .mismatchedPicture: "the picture isn't the encoder's size and format"
        case .noData: "the sample has no bytes"
        case .codec(let code, let message): "libavcodec error \(code): \(message)"
        }
    }

    /// libavcodec's error, described.
    static func ffmpeg(_ code: Int32) -> VideoCodecError {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return .codec(code: code, message: message)
    }
}

/// Throws libavcodec's error for a negative result.
@discardableResult
func check(_ result: Int32) throws -> Int32 {
    guard result >= 0 else { throw VideoCodecError.ffmpeg(result) }
    return result
}
