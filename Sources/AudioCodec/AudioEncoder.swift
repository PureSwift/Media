import CFFmpeg
import CFFmpegResample
import MediaCore

/// Encodes linear PCM to coded audio, such as AAC, Opus or FLAC, on
/// libavcodec.
///
/// Give it PCM in any layout, rate and channels libswresample converts, in
/// buffers of any size; it cuts the audio into the codec's frames, and gives
/// coded packets, each a sample buffer timed in the encoder's rate. After
/// the last PCM, `finish` returns the rest. An encoder is for one thread at
/// a time.
public final class AudioEncoder {

    /// What an encoder makes.
    public struct Settings: Sendable {

        public var codec: CodecType

        public var sampleRate: Double

        public var channelLayout: ChannelLayout

        /// Bits a second; nil leaves it to the codec.
        public var bitRate: Int?

        public init(codec: CodecType, sampleRate: Double, channelLayout: ChannelLayout, bitRate: Int? = nil) {
            self.codec = codec
            self.sampleRate = sampleRate
            self.channelLayout = channelLayout
            self.bitRate = bitRate
        }
    }

    public let settings: Settings

    /// The coded audio's format, with the codec's magic cookie and frames
    /// per packet, as a file's track needs.
    public let format: AudioFormat

    private let context: UnsafeMutablePointer<AVCodecContext>

    private let frame: UnsafeMutablePointer<AVFrame>

    private let packet: UnsafeMutablePointer<AVPacket>

    /// PCM converted to the codec's format, waiting for a whole frame.
    private let fifo: OpaquePointer

    /// The codec's format, which the resampler converts to.
    private let codecFormat: Resampler.Format

    private var resampler: Resampler?

    /// Frames each encoded frame takes.
    private let frameSize: Int

    /// Whether the codec takes a short last frame, or it's padded.
    private let takesShortLastFrame: Bool

    /// The time of the first frame in the FIFO, in the encoder's rate.
    private var nextTimestamp: Int64?

    private var finished = false

    public init(settings: Settings) throws {
        guard let id = settings.codec.audioCodecID, let codec = avcodec_find_encoder(id) else {
            throw AudioCodecError.unsupportedCodec(settings.codec)
        }
        guard let context = avcodec_alloc_context3(codec) else { throw AudioCodecError.unsupportedCodec(settings.codec) }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        let rate = Int32(settings.sampleRate.rounded())
        var sampleFormat = cffmpeg_encoder_sample_format(codec, context)
        if sampleFormat == AV_SAMPLE_FMT_NONE { sampleFormat = AV_SAMPLE_FMT_FLTP }
        context.pointee.sample_fmt = sampleFormat
        context.pointee.sample_rate = rate
        av_channel_layout_uninit(&context.pointee.ch_layout)
        av_channel_layout_default(&context.pointee.ch_layout, Int32(clamping: settings.channelLayout.channels.count))
        context.pointee.time_base = AVRational(num: 1, den: rate)
        if let bitRate = settings.bitRate { context.pointee.bit_rate = Int64(bitRate) }
        // The magic cookie in extradata, as MP4 keeps it.
        cffmpeg_context_set_global_header(context)
        let opened = avcodec_open2(context, codec, nil)
        guard opened >= 0 else {
            avcodec_free_context(&owned)
            throw AudioCodecError.ffmpeg(opened)
        }
        let codecFormat = Resampler.Format(sampleFormat: sampleFormat, sampleRate: rate, channelCount: context.pointee.ch_layout.nb_channels)
        guard let frame = av_frame_alloc(), let packet = av_packet_alloc(),
              let fifo = av_audio_fifo_alloc(sampleFormat, codecFormat.channelCount, 1) else {
            avcodec_free_context(&owned)
            throw AudioCodecError.ffmpeg(cffmpeg_error_again())
        }
        var cookie: [UInt8] = []
        if let extradata = context.pointee.extradata, context.pointee.extradata_size > 0 {
            cookie = Array(UnsafeBufferPointer(start: extradata, count: Int(context.pointee.extradata_size)))
        }
        let anySize = cffmpeg_codec_takes_any_frame_size(codec) != 0
        self.settings = settings
        self.context = context
        self.frame = frame
        self.packet = packet
        self.fifo = fifo
        self.codecFormat = codecFormat
        self.frameSize = context.pointee.frame_size > 0 && !anySize ? Int(context.pointee.frame_size) : 1024
        self.takesShortLastFrame = anySize || cffmpeg_codec_takes_small_last_frame(codec) != 0
        self.format = AudioFormat(
            codec: settings.codec, sampleRate: Double(rate), channelLayout: settings.channelLayout,
            framesPerPacket: anySize ? 0 : Int(context.pointee.frame_size), magicCookie: cookie
        )
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        av_audio_fifo_free(fifo)
    }

    /// Encodes a buffer of linear PCM: the packets that became ready,
    /// perhaps none yet. Its time places the first; the rest follow on.
    public func encode(_ pcm: SampleBuffer) throws -> [SampleBuffer] {
        guard case .audio(let audio)? = pcm.format, audio.codec == .linearPCM, let layout = audio.pcm,
              let data = pcm.data, let bytesPerFrame = audio.bytesPerFrame, bytesPerFrame > 0,
              data.count % bytesPerFrame == 0 else {
            throw AudioCodecError.mismatchedAudio
        }
        guard let sampleFormat = layout.sampleFormat else { throw AudioCodecError.unsupportedLayout(layout.name) }
        let input = Resampler.Format(sampleFormat: sampleFormat, sampleRate: Int32(audio.sampleRate.rounded()),
                                     channelCount: Int32(clamping: audio.channelCount))
        if resampler?.input != input {
            resampler = try Resampler(from: input, to: codecFormat)
        }
        if nextTimestamp == nil {
            nextTimestamp = pcm.presentationTime.isNumeric ? pcm.presentationTime.timestamp(in: codecFormat.sampleRate) : 0
        }
        let frames = data.count / bytesPerFrame
        let converted = try data.withUnsafeBytes { bytes in
            let planeSize = frames * input.bytesPerFramePerPlane
            let planes = (0..<input.planeCount).map {
                UnsafePointer<UInt8>?(bytes.baseAddress!.advanced(by: $0 * planeSize).assumingMemoryBound(to: UInt8.self))
            }
            return try resampler!.convert(planes, frames: frames)
        }
        try enqueue(converted)
        return try encodeWholeFrames()
    }

    /// The packets still held, once there's no more PCM: a short last frame
    /// is padded with silence where the codec needs.
    public func finish() throws -> [SampleBuffer] {
        guard !finished else { return [] }
        finished = true
        if let resampler { try enqueue(resampler.convert([], frames: 0)) }
        var packets = try encodeWholeFrames()
        let left = Int(av_audio_fifo_size(fifo))
        if left > 0 { packets += try encodeFrame(of: left) }
        return packets + (try send(nil))
    }

    /// Converted PCM into the FIFO.
    private func enqueue(_ converted: (bytes: [UInt8], frames: Int)) throws {
        guard converted.frames > 0 else { return }
        try converted.bytes.withUnsafeBytes { bytes in
            let planeSize = converted.frames * codecFormat.bytesPerFramePerPlane
            var planes: [UnsafeMutableRawPointer?] = (0..<codecFormat.planeCount).map {
                UnsafeMutableRawPointer(mutating: bytes.baseAddress!.advanced(by: $0 * planeSize))
            }
            let written = av_audio_fifo_write(fifo, &planes, Int32(converted.frames))
            guard try check(written) == Int32(converted.frames) else { throw AudioCodecError.ffmpeg(cffmpeg_error_again()) }
        }
    }

    private func encodeWholeFrames() throws -> [SampleBuffer] {
        var packets: [SampleBuffer] = []
        while Int(av_audio_fifo_size(fifo)) >= frameSize {
            packets += try encodeFrame(of: frameSize)
        }
        return packets
    }

    /// Encodes `count` frames from the FIFO, padded to a whole frame when
    /// the codec needs.
    private func encodeFrame(of count: Int) throws -> [SampleBuffer] {
        let size = count < frameSize && !takesShortLastFrame ? frameSize : count
        frame.pointee.nb_samples = Int32(size)
        frame.pointee.format = codecFormat.sampleFormat.rawValue
        frame.pointee.sample_rate = codecFormat.sampleRate
        try check(av_channel_layout_copy(&frame.pointee.ch_layout, &context.pointee.ch_layout))
        try check(av_frame_get_buffer(frame, 0))
        defer { av_frame_unref(frame) }
        let planes = UnsafeMutableRawPointer(frame.pointee.extended_data)
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        if size > count {
            try check(av_samples_set_silence(frame.pointee.extended_data, 0, Int32(size), codecFormat.channelCount, codecFormat.sampleFormat))
        }
        try check(av_audio_fifo_read(fifo, planes, Int32(count)))
        let timestamp = nextTimestamp ?? 0
        frame.pointee.pts = timestamp
        nextTimestamp = timestamp + Int64(count)
        return try send(frame)
    }

    private func send(_ frame: UnsafeMutablePointer<AVFrame>?) throws -> [SampleBuffer] {
        var packets: [SampleBuffer] = []
        while true {
            let sent = avcodec_send_frame(context, frame)
            if sent == cffmpeg_error_again() {
                let taken = try receive()
                packets += taken
                if taken.isEmpty { throw AudioCodecError.ffmpeg(sent) }
                continue
            }
            if sent == cffmpeg_error_eof(), frame == nil { return packets }
            try check(sent)
            break
        }
        return packets + (try receive())
    }

    private func receive() throws -> [SampleBuffer] {
        var packets: [SampleBuffer] = []
        let scale = codecFormat.sampleRate
        while true {
            let received = avcodec_receive_packet(context, packet)
            if received == cffmpeg_error_again() || received == cffmpeg_error_eof() { return packets }
            try check(received)
            defer { av_packet_unref(packet) }
            // FLAC ends with a packet of only side data: its header, updated.
            guard packet.pointee.size > 0 else { continue }
            let bytes = BlockBuffer(bytes: UnsafeBufferPointer(start: packet.pointee.data, count: Int(packet.pointee.size)))
            let timing = SampleTiming(
                presentationTime: MediaTime(timestamp: packet.pointee.pts, timescale: scale),
                decodeTime: MediaTime(timestamp: packet.pointee.dts, timescale: scale),
                duration: packet.pointee.duration > 0 ? MediaTime(value: packet.pointee.duration, timescale: scale) : .invalid
            )
            packets.append(SampleBuffer(data: bytes, format: .audio(format), timing: timing, flags: .sync))
        }
    }
}
