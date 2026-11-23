import CFFmpeg
import MediaCore
import PixelBuffers

// Media's codecs, pixel formats and color as FFmpeg's, and back.

extension CodecType {

    /// libavcodec's codec for this one.
    var codecID: AVCodecID? {
        switch self {
        case .h264, "avc3": AV_CODEC_ID_H264
        case .hevc, "hev1": AV_CODEC_ID_HEVC
        case .av1: AV_CODEC_ID_AV1
        case .vp8: AV_CODEC_ID_VP8
        case .vp9: AV_CODEC_ID_VP9
        case .mpeg4Video: AV_CODEC_ID_MPEG4
        case .jpeg: AV_CODEC_ID_MJPEG
        case .proRes422: AV_CODEC_ID_PRORES
        default: nil
        }
    }
}

extension PixelFormat {

    /// The pixel format FFmpeg calls this one.
    var ffmpegFormat: AVPixelFormat? {
        switch self {
        case .i420: AV_PIX_FMT_YUV420P
        case .nv12: AV_PIX_FMT_NV12
        case .p010: AV_PIX_FMT_P010LE
        case .bgra8: AV_PIX_FMT_BGRA
        case .rgba8: AV_PIX_FMT_RGBA
        case .gray8: AV_PIX_FMT_GRAY8
        default: nil
        }
    }

    /// The format of FFmpeg's pixel format; nil for one this library
    /// doesn't describe. Full-range JPEG YUV is I420, with its range in
    /// the color.
    init?(ffmpeg format: AVPixelFormat) {
        switch format {
        case AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P: self = .i420
        case AV_PIX_FMT_NV12: self = .nv12
        case AV_PIX_FMT_P010LE: self = .p010
        case AV_PIX_FMT_BGRA: self = .bgra8
        case AV_PIX_FMT_RGBA: self = .rgba8
        case AV_PIX_FMT_GRAY8: self = .gray8
        default: return nil
        }
    }
}

/// FFmpeg's name for a pixel format.
func name(of format: AVPixelFormat) -> String {
    av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "\(format.rawValue)"
}

extension ColorInfo {

    /// A frame's color. FFmpeg numbers primaries, transfer functions and
    /// matrices by H.273's code points, as this library does.
    init(frame: UnsafePointer<AVFrame>) {
        let primaries = UInt8(clamping: frame.pointee.color_primaries.rawValue)
        let transfer = UInt8(clamping: frame.pointee.color_trc.rawValue)
        let matrix = UInt8(clamping: frame.pointee.colorspace.rawValue)
        let chroma: ChromaLocation? = switch frame.pointee.chroma_location {
        case AVCHROMA_LOC_LEFT: .left
        case AVCHROMA_LOC_CENTER: .center
        case AVCHROMA_LOC_TOPLEFT: .topLeft
        default: nil
        }
        self.init(
            primaries: ColorPrimaries(rawValue: primaries),
            transferFunction: TransferFunction(rawValue: transfer),
            matrix: MatrixCoefficients(rawValue: matrix),
            range: frame.pointee.color_range == AVCOL_RANGE_JPEG || frame.pointee.format == AV_PIX_FMT_YUVJ420P.rawValue ? .full : .video,
            chromaLocation: chroma
        )
    }

    /// Gives an encoder's context this color.
    func apply(to context: UnsafeMutablePointer<AVCodecContext>) {
        context.pointee.color_primaries = AVColorPrimaries(rawValue: UInt32(primaries.rawValue))
        context.pointee.color_trc = AVColorTransferCharacteristic(rawValue: UInt32(transferFunction.rawValue))
        context.pointee.colorspace = AVColorSpace(rawValue: UInt32(matrix.rawValue))
        context.pointee.color_range = range == .full ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
        context.pointee.chroma_sample_location = switch chromaLocation {
        case .left: AVCHROMA_LOC_LEFT
        case .center: AVCHROMA_LOC_CENTER
        case .topLeft: AVCHROMA_LOC_TOPLEFT
        case nil: AVCHROMA_LOC_UNSPECIFIED
        }
    }
}

extension MediaTime {

    /// The time in units of `1 / timescale`, as FFmpeg's timestamps are;
    /// FFmpeg's "no timestamp" for a time that isn't a number.
    func timestamp(in timescale: Int32) -> Int64 {
        let converted = converted(to: timescale)
        return converted.isNumeric ? converted.value : cffmpeg_no_timestamp()
    }

    /// A timestamp in units of `1 / timescale`; invalid for FFmpeg's "no
    /// timestamp".
    init(timestamp: Int64, timescale: Int32) {
        self = timestamp == cffmpeg_no_timestamp() ? .invalid : MediaTime(value: timestamp, timescale: timescale)
    }
}
