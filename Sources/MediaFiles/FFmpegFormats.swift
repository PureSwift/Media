import CFFmpegFormat
import MediaCore

// Tracks' formats as libavformat's codec parameters, and back, and media
// time in its time bases.

/// Codecs by libavcodec's IDs, and the codec types this library names them
/// by, both ways.
private let codecs: [(AVCodecID, CodecType)] = [
    (AV_CODEC_ID_H264, .h264),
    (AV_CODEC_ID_HEVC, .hevc),
    (AV_CODEC_ID_AV1, .av1),
    (AV_CODEC_ID_VP8, .vp8),
    (AV_CODEC_ID_VP9, .vp9),
    (AV_CODEC_ID_MPEG4, .mpeg4Video),
    (AV_CODEC_ID_MJPEG, .jpeg),
    (AV_CODEC_ID_PRORES, .proRes422),
    (AV_CODEC_ID_AAC, .aac),
    (AV_CODEC_ID_OPUS, .opus),
    (AV_CODEC_ID_MP3, .mp3),
    (AV_CODEC_ID_FLAC, .flac),
    (AV_CODEC_ID_VORBIS, .vorbis),
    (AV_CODEC_ID_AC3, .ac3),
    (AV_CODEC_ID_EAC3, .eac3),
    (AV_CODEC_ID_ALAC, .alac),
    (AV_CODEC_ID_MOV_TEXT, "tx3g"),
    (AV_CODEC_ID_WEBVTT, "wvtt"),
    (AV_CODEC_ID_SUBRIP, "srt "),
]

/// Linear PCM's codecs, and how each stores its samples.
private let pcmCodecs: [(AVCodecID, PCMLayout)] = [
    (AV_CODEC_ID_PCM_S16LE, PCMLayout(sampleType: .signedInteger, bitsPerSample: 16)),
    (AV_CODEC_ID_PCM_S16BE, PCMLayout(sampleType: .signedInteger, bitsPerSample: 16, isBigEndian: true)),
    (AV_CODEC_ID_PCM_S24LE, PCMLayout(sampleType: .signedInteger, bitsPerSample: 24)),
    (AV_CODEC_ID_PCM_S24BE, PCMLayout(sampleType: .signedInteger, bitsPerSample: 24, isBigEndian: true)),
    (AV_CODEC_ID_PCM_S32LE, PCMLayout(sampleType: .signedInteger, bitsPerSample: 32)),
    (AV_CODEC_ID_PCM_S32BE, PCMLayout(sampleType: .signedInteger, bitsPerSample: 32, isBigEndian: true)),
    (AV_CODEC_ID_PCM_F32LE, PCMLayout(sampleType: .float, bitsPerSample: 32)),
    (AV_CODEC_ID_PCM_F32BE, PCMLayout(sampleType: .float, bitsPerSample: 32, isBigEndian: true)),
    (AV_CODEC_ID_PCM_F64LE, PCMLayout(sampleType: .float, bitsPerSample: 64)),
    (AV_CODEC_ID_PCM_U8, PCMLayout(sampleType: .unsignedInteger, bitsPerSample: 8)),
]

/// libavcodec's name for a codec.
func name(of codec: AVCodecID) -> String {
    avcodec_get_name(codec).map { String(cString: $0) } ?? "\(codec.rawValue)"
}

extension FormatDescription {

    /// A stream's format, from its codec parameters; nil for a codec this
    /// library can't name, without a four-character tag of its own.
    init?(parameters: UnsafePointer<AVCodecParameters>) {
        let p = parameters.pointee
        let configuration = p.extradata.map { Array(UnsafeBufferPointer(start: $0, count: Int(p.extradata_size))) } ?? []
        var codec = codecs.first { $0.0 == p.codec_id }?.1
        let pcm = pcmCodecs.first { $0.0 == p.codec_id }?.1
        if pcm != nil { codec = .linearPCM }
        if codec == nil, p.codec_tag != 0 {
            // A tag's bytes are little-endian: its first character is the low byte.
            codec = CodecType(rawValue: FourCharacterCode(rawValue: p.codec_tag.byteSwapped))
        }
        guard let codec else { return nil }
        switch p.codec_type {
        case AVMEDIA_TYPE_VIDEO:
            let aspect = p.sample_aspect_ratio
            let chroma: ChromaLocation? = switch p.chroma_location {
            case AVCHROMA_LOC_LEFT: .left
            case AVCHROMA_LOC_CENTER: .center
            case AVCHROMA_LOC_TOPLEFT: .topLeft
            default: nil
            }
            let color = ColorInfo(
                primaries: ColorPrimaries(rawValue: UInt8(clamping: p.color_primaries.rawValue)),
                transferFunction: TransferFunction(rawValue: UInt8(clamping: p.color_trc.rawValue)),
                matrix: MatrixCoefficients(rawValue: UInt8(clamping: p.color_space.rawValue)),
                range: p.color_range == AVCOL_RANGE_JPEG ? .full : .video,
                chromaLocation: chroma
            )
            self = .video(VideoFormat(
                codec: codec, width: Int(p.width), height: Int(p.height),
                pixelAspectRatio: aspect.num > 0 && aspect.den > 0 ? (Int(aspect.num), Int(aspect.den)) : (1, 1),
                color: color, configuration: configuration
            ))
        case AVMEDIA_TYPE_AUDIO:
            self = .audio(AudioFormat(
                codec: codec,
                sampleRate: Double(p.sample_rate),
                channelLayout: .standard(channelCount: Int(p.ch_layout.nb_channels)),
                pcm: pcm,
                framesPerPacket: pcm != nil ? 1 : Int(p.frame_size),
                magicCookie: configuration
            ))
        case AVMEDIA_TYPE_SUBTITLE:
            self = .other(.text, codec)
        case AVMEDIA_TYPE_DATA:
            self = .other(.metadata, codec)
        default:
            return nil
        }
    }

    /// Gives a stream's codec parameters this format.
    func apply(to parameters: UnsafeMutablePointer<AVCodecParameters>) throws {
        let codecID: AVCodecID
        if case .audio(let audio) = self, audio.codec == .linearPCM {
            guard let pcm = audio.pcm, let match = pcmCodecs.first(where: { $0.1 == pcm }) else {
                throw MediaFilesError.unsupportedFormat("linear PCM laid out as \(String(describing: audio.pcm))")
            }
            codecID = match.0
        } else if let match = codecs.first(where: { $0.1 == codec }) {
            codecID = match.0
        } else {
            throw MediaFilesError.unsupportedFormat("codec \(codec)")
        }
        parameters.pointee.codec_id = codecID
        var extra: [UInt8] = []
        switch self {
        case .video(let video):
            parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            parameters.pointee.width = Int32(clamping: video.width)
            parameters.pointee.height = Int32(clamping: video.height)
            parameters.pointee.sample_aspect_ratio = AVRational(
                num: Int32(clamping: video.pixelAspectRatio.horizontal), den: Int32(clamping: video.pixelAspectRatio.vertical))
            parameters.pointee.color_primaries = AVColorPrimaries(rawValue: UInt32(video.color.primaries.rawValue))
            parameters.pointee.color_trc = AVColorTransferCharacteristic(rawValue: UInt32(video.color.transferFunction.rawValue))
            parameters.pointee.color_space = AVColorSpace(rawValue: UInt32(video.color.matrix.rawValue))
            parameters.pointee.color_range = video.color.range == .full ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
            extra = video.configuration
        case .audio(let audio):
            parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            parameters.pointee.sample_rate = Int32(audio.sampleRate.rounded())
            av_channel_layout_uninit(&parameters.pointee.ch_layout)
            av_channel_layout_default(&parameters.pointee.ch_layout, Int32(clamping: audio.channelCount))
            parameters.pointee.frame_size = Int32(clamping: audio.framesPerPacket)
            if let pcm = audio.pcm {
                parameters.pointee.bits_per_coded_sample = Int32(clamping: pcm.bitsPerSample)
            }
            extra = audio.magicCookie
        case .other(let type, _):
            parameters.pointee.codec_type = type == .text ? AVMEDIA_TYPE_SUBTITLE : AVMEDIA_TYPE_DATA
        }
        guard !extra.isEmpty else { return }
        // libavformat reads past the end: the padding is zeroed.
        guard let extradata = av_mallocz(extra.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self) else {
            throw MediaFilesError.ffmpeg(cffmpeg_format_error_again())
        }
        extra.withUnsafeBufferPointer { extradata.update(from: $0.baseAddress!, count: extra.count) }
        parameters.pointee.extradata = extradata
        parameters.pointee.extradata_size = Int32(extra.count)
    }
}

extension MediaTime {

    /// A timestamp in a stream's time base; invalid for libavformat's "no
    /// timestamp".
    init(timestamp: Int64, timeBase: AVRational) {
        guard timestamp != cffmpeg_format_no_timestamp(), timeBase.den > 0 else {
            self = .invalid
            return
        }
        guard timeBase.num != 1 else {
            self = MediaTime(value: timestamp, timescale: timeBase.den)
            return
        }
        let (value, overflow) = timestamp.multipliedReportingOverflow(by: Int64(timeBase.num))
        self = overflow ? (timestamp < 0 ? .negativeInfinity : .positiveInfinity) : MediaTime(value: value, timescale: timeBase.den)
    }

    /// The time in a stream's time base, the nearest timestamp; "no
    /// timestamp" for a time that isn't a number.
    func timestamp(in timeBase: AVRational) -> Int64 {
        guard isNumeric else { return cffmpeg_format_no_timestamp() }
        return av_rescale_q(value, AVRational(num: 1, den: timescale), timeBase)
    }
}
