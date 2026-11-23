import CFFmpeg
import MediaCore

// Media's audio codecs and PCM layouts as FFmpeg's, and back.

extension CodecType {

    /// libavcodec's codec for this audio one.
    var audioCodecID: AVCodecID? {
        switch self {
        case .aac: AV_CODEC_ID_AAC
        case .opus: AV_CODEC_ID_OPUS
        case .mp3: AV_CODEC_ID_MP3
        case .flac: AV_CODEC_ID_FLAC
        case .vorbis: AV_CODEC_ID_VORBIS
        case .ac3: AV_CODEC_ID_AC3
        case .eac3: AV_CODEC_ID_EAC3
        case .alac: AV_CODEC_ID_ALAC
        default: nil
        }
    }
}

extension PCMLayout {

    /// libavutil's sample format for this layout; nil for 24-bit and
    /// big-endian samples, which it has none for.
    var sampleFormat: AVSampleFormat? {
        guard !isBigEndian else { return nil }
        return switch (sampleType, bitsPerSample) {
        case (.unsignedInteger, 8): isInterleaved ? AV_SAMPLE_FMT_U8 : AV_SAMPLE_FMT_U8P
        case (.signedInteger, 16): isInterleaved ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S16P
        case (.signedInteger, 32): isInterleaved ? AV_SAMPLE_FMT_S32 : AV_SAMPLE_FMT_S32P
        case (.float, 32): isInterleaved ? AV_SAMPLE_FMT_FLT : AV_SAMPLE_FMT_FLTP
        case (.float, 64): isInterleaved ? AV_SAMPLE_FMT_DBL : AV_SAMPLE_FMT_DBLP
        default: nil
        }
    }

    /// The layout of libavutil's sample format.
    init?(sampleFormat: AVSampleFormat) {
        let planar = av_sample_fmt_is_planar(sampleFormat) != 0
        switch av_get_packed_sample_fmt(sampleFormat) {
        case AV_SAMPLE_FMT_U8: self.init(sampleType: .unsignedInteger, bitsPerSample: 8, isInterleaved: !planar)
        case AV_SAMPLE_FMT_S16: self.init(sampleType: .signedInteger, bitsPerSample: 16, isInterleaved: !planar)
        case AV_SAMPLE_FMT_S32: self.init(sampleType: .signedInteger, bitsPerSample: 32, isInterleaved: !planar)
        case AV_SAMPLE_FMT_FLT: self.init(sampleType: .float, bitsPerSample: 32, isInterleaved: !planar)
        case AV_SAMPLE_FMT_DBL: self.init(sampleType: .float, bitsPerSample: 64, isInterleaved: !planar)
        default: return nil
        }
    }

    var name: String {
        let type = switch sampleType {
        case .signedInteger: "signed"
        case .unsignedInteger: "unsigned"
        case .float: "float"
        }
        return "\(bitsPerSample)-bit \(type)\(isInterleaved ? "" : " planar")\(isBigEndian ? " big-endian" : "")"
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
