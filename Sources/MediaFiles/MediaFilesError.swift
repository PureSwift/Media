import CFFmpegFormat

/// Why a media file couldn't be read or written.
public enum MediaFilesError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file or stream couldn't be opened or understood.
    case cannotOpen(String, message: String)
    /// No container for the name or the file's extension.
    case unknownContainer(String)
    /// No track with the number.
    case noSuchTrack(Int)
    /// A track's format the container can't hold, or this library can't
    /// describe.
    case unsupportedFormat(String)
    /// Tracks were added once samples had been written.
    case alreadyWriting
    /// The writer has finished.
    case finished
    /// libavformat failed: its error code and description.
    case format(code: Int32, message: String)

    public var description: String {
        switch self {
        case .cannotOpen(let url, let message): "can't open \(url): \(message)"
        case .unknownContainer(let name): "no container \(name)"
        case .noSuchTrack(let track): "no track \(track)"
        case .unsupportedFormat(let what): "unsupported format: \(what)"
        case .alreadyWriting: "tracks can't be added once samples are written"
        case .finished: "the writer has finished"
        case .format(let code, let message): "libavformat error \(code): \(message)"
        }
    }

    /// libavformat's error, described.
    static func ffmpeg(_ code: Int32) -> MediaFilesError {
        .format(code: code, message: describe(code))
    }

    static func describe(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// Throws libavformat's error for a negative result.
@discardableResult
func check(_ result: Int32) throws -> Int32 {
    guard result >= 0 else { throw MediaFilesError.ffmpeg(result) }
    return result
}
