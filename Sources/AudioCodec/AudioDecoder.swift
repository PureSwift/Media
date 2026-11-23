import CFFmpeg
import CFFmpegResample
import MediaCore

/// Decodes coded audio, such as AAC or Opus, to linear PCM, on libavcodec,
/// converted by libswresample to the layout, rate and channels asked for.
/// Linear PCM decodes too, in any interleaved layout, 24-bit and
/// big-endian included, which converts it.
///
/// Give it a track's samples in decode order; each `decode` returns the PCM
/// that became ready, as sample buffers of `sampleCount` frames each. After
/// the last sample, `finish` returns the rest; after a seek, `reset` drops
/// what it holds. A decoder is for one thread at a time.
public final class AudioDecoder {

    /// The PCM a decoder gives.
    public struct Options: Sendable {

        /// How its samples are laid out: 32-bit floats, interleaved, by
        /// default.
        public var layout: PCMLayout

        /// Its rate; nil keeps the audio's.
        public var sampleRate: Double?

        /// Its channels; nil keeps the audio's, in the usual order for their
        /// count.
        public var channelLayout: ChannelLayout?

        public init(layout: PCMLayout = .float32, sampleRate: Double? = nil, channelLayout: ChannelLayout? = nil) {
            self.layout = layout
            self.sampleRate = sampleRate
            self.channelLayout = channelLayout
        }
    }

    /// The audio it decodes.
    public let format: AudioFormat

    public let options: Options

    private let codec: UnsafePointer<AVCodec>

    private let outputSampleFormat: AVSampleFormat

    private var context: UnsafeMutablePointer<AVCodecContext>?

    private let packet: UnsafeMutablePointer<AVPacket>

    private let frame: UnsafeMutablePointer<AVFrame>

    private var resampler: Resampler?

    /// The scale of the timestamps libavcodec is given and gives back: the
    /// first sample's.
    private var timescale: Int32 = 0

    /// When the next PCM starts, for frames without a timestamp.
    private var nextTime: MediaTime = .invalid

    /// A decoder for `format`'s codec, which starts from its magic cookie.
    public init(format: AudioFormat, options: Options = Options()) throws {
        guard let id = format.decoderCodecID, let codec = avcodec_find_decoder(id) else {
            throw AudioCodecError.unsupportedCodec(format.codec)
        }
        guard let outputSampleFormat = options.layout.sampleFormat else {
            throw AudioCodecError.unsupportedLayout(options.layout.name)
        }
        guard let packet = av_packet_alloc() else { throw AudioCodecError.ffmpeg(cffmpeg_error_again()) }
        guard let frame = av_frame_alloc() else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            throw AudioCodecError.ffmpeg(cffmpeg_error_again())
        }
        self.format = format
        self.options = options
        self.codec = codec
        self.outputSampleFormat = outputSampleFormat
        self.packet = packet
        self.frame = frame
    }

    deinit {
        var context = context
        avcodec_free_context(&context)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
    }

    /// Opens libavcodec's decoder, with timestamps in `timescale`.
    private func open(timescale: Int32) throws -> UnsafeMutablePointer<AVCodecContext> {
        if let context { return context }
        guard let context = avcodec_alloc_context3(codec) else { throw AudioCodecError.unsupportedCodec(format.codec) }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        if format.sampleRate > 0 { context.pointee.sample_rate = Int32(format.sampleRate.rounded()) }
        if format.channelCount > 0 {
            av_channel_layout_uninit(&context.pointee.ch_layout)
            av_channel_layout_default(&context.pointee.ch_layout, Int32(clamping: format.channelCount))
        }
        context.pointee.pkt_timebase = AVRational(num: 1, den: timescale)
        if !format.magicCookie.isEmpty {
            // libavcodec reads past the end: the padding is zeroed.
            let size = format.magicCookie.count
            guard let extradata = av_mallocz(size + Int(cffmpeg_input_padding()))?.assumingMemoryBound(to: UInt8.self) else {
                avcodec_free_context(&owned)
                throw AudioCodecError.ffmpeg(cffmpeg_error_again())
            }
            format.magicCookie.withUnsafeBufferPointer { extradata.update(from: $0.baseAddress!, count: size) }
            context.pointee.extradata = extradata
            context.pointee.extradata_size = Int32(size)
        }
        let result = avcodec_open2(context, codec, nil)
        guard result >= 0 else {
            avcodec_free_context(&owned)
            throw AudioCodecError.ffmpeg(result)
        }
        self.context = context
        self.timescale = timescale
        return context
    }

    /// Decodes a sample of coded audio, or several packets back to back:
    /// the PCM that became ready, perhaps none yet.
    public func decode(_ sample: SampleBuffer) throws -> [SampleBuffer] {
        guard let data = sample.data, !data.isEmpty else { throw AudioCodecError.noData }
        let timing = sample.timing
        let scale = timescale > 0 ? timescale
            : timing.presentationTime.isNumeric ? timing.presentationTime.timescale
            : format.sampleRate > 0 ? Int32(format.sampleRate.rounded()) : 48_000
        let context = try open(timescale: scale)
        var output: [SampleBuffer] = []
        for (index, bytes) in sample.samples.enumerated() where !bytes.isEmpty {
            try check(av_new_packet(packet, Int32(clamping: bytes.count)))
            defer { av_packet_unref(packet) }
            bytes.withUnsafeBytes { bytes in
                packet.pointee.data.update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            }
            // Only the first packet's time is known.
            packet.pointee.pts = index == 0 ? timing.presentationTime.timestamp(in: scale) : cffmpeg_no_timestamp()
            packet.pointee.dts = index == 0 ? timing.decodeTime.timestamp(in: scale) : cffmpeg_no_timestamp()
            while true {
                let sent = avcodec_send_packet(context, packet)
                if sent == cffmpeg_error_again() {
                    let taken = try receive(from: context)
                    output += taken
                    if taken.isEmpty { throw AudioCodecError.ffmpeg(sent) }
                    continue
                }
                try check(sent)
                break
            }
            output += try receive(from: context)
        }
        return output
    }

    /// The PCM still held, once there are no more samples. The decoder then
    /// starts over, for samples after a seek.
    public func finish() throws -> [SampleBuffer] {
        guard let context else { return [] }
        try check(avcodec_send_packet(context, nil))
        var output = try receive(from: context)
        if let resampler, let drained = try pcm(resampler.convert([], frames: 0), from: resampler) {
            output.append(drained)
        }
        reset()
        return output
    }

    /// Drops the samples and PCM held, as after a seek.
    public func reset() {
        guard let context else { return }
        avcodec_flush_buffers(context)
        resampler = nil
        nextTime = .invalid
    }

    /// Every frame ready, converted.
    private func receive(from context: UnsafeMutablePointer<AVCodecContext>) throws -> [SampleBuffer] {
        var output: [SampleBuffer] = []
        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == cffmpeg_error_again() || received == cffmpeg_error_eof() { return output }
            try check(received)
            defer { av_frame_unref(frame) }
            if let converted = try convert(frame) { output.append(converted) }
        }
    }

    /// A decoded frame, converted to the PCM asked for.
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) throws -> SampleBuffer? {
        let input = Resampler.Format(
            sampleFormat: AVSampleFormat(rawValue: frame.pointee.format),
            sampleRate: frame.pointee.sample_rate,
            channelCount: frame.pointee.ch_layout.nb_channels
        )
        let resampler: Resampler
        if let current = self.resampler, current.input == input {
            resampler = current
        } else {
            // The first frame, or the audio changed: a new resampler, and
            // what the old one held is lost.
            let output = Resampler.Format(
                sampleFormat: outputSampleFormat,
                sampleRate: options.sampleRate.map { Int32($0.rounded()) } ?? input.sampleRate,
                channelCount: options.channelLayout.map { Int32(clamping: $0.channels.count) } ?? input.channelCount
            )
            resampler = try Resampler(from: input, to: output, inputLayout: &frame.pointee.ch_layout)
            self.resampler = resampler
        }
        let timestamp = frame.pointee.best_effort_timestamp != cffmpeg_no_timestamp()
            ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        if timestamp != cffmpeg_no_timestamp() {
            // The PCM out starts as far back as the resampler holds.
            nextTime = MediaTime(value: timestamp, timescale: timescale) - MediaTime(value: resampler.delay, timescale: resampler.output.sampleRate)
        }
        let planes = UnsafeRawPointer(frame.pointee.extended_data)
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let inputs = (0..<input.planeCount).map { planes[$0] }
        return try pcm(resampler.convert(inputs, frames: Int(frame.pointee.nb_samples)), from: resampler)
    }

    /// Converted PCM as a sample buffer, timed from the last; nil for none.
    private func pcm(_ converted: (bytes: [UInt8], frames: Int), from resampler: Resampler) throws -> SampleBuffer? {
        guard converted.frames > 0 else { return nil }
        let rate = resampler.output.sampleRate
        let channels = options.channelLayout ?? .standard(channelCount: Int(resampler.output.channelCount))
        let duration = MediaTime(value: Int64(converted.frames), timescale: rate)
        let start = nextTime.isNumeric ? nextTime : .zero
        nextTime = start + duration
        return SampleBuffer(
            content: .data(BlockBuffer(bytes: converted.bytes)),
            format: .audio(.linearPCM(sampleRate: Double(rate), channelLayout: channels, layout: options.layout)),
            timing: SampleTiming(presentationTime: start, duration: duration),
            sampleCount: converted.frames,
            flags: .sync
        )
    }
}
