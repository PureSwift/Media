import CFFmpeg
import MediaCore
import PixelBuffers

/// Decodes coded video, such as H.264 or HEVC, to pictures, on libavcodec.
///
/// Give it a track's samples in decode order; each `decode` returns the
/// pictures that became ready, in presentation order, as sample buffers
/// whose content is a `PixelBuffer`. A decoder may hold samples back before
/// it returns any (B-frames reorder), so after the last sample, `finish`
/// returns the rest. After a seek, `reset` drops what it holds.
///
/// Each picture's pixels are libavcodec's own frame, not a copy, and are
/// freed when the pixel buffer goes. A decoder is for one thread at a time.
public final class VideoDecoder {

    /// How a decoder works.
    public struct Options: Sendable {

        /// Threads to decode with: 0 lets libavcodec choose.
        public var threadCount: Int

        public init(threadCount: Int = 0) {
            self.threadCount = threadCount
        }
    }

    /// The video it decodes.
    public let format: VideoFormat

    public let options: Options

    private let codec: UnsafePointer<AVCodec>

    private var context: UnsafeMutablePointer<AVCodecContext>?

    private let packet: UnsafeMutablePointer<AVPacket>

    private let frame: UnsafeMutablePointer<AVFrame>

    /// The scale of the timestamps libavcodec is given and gives back: the
    /// first sample's.
    private var timescale: Int32 = 0

    /// A decoder for `format`'s codec, which starts from its configuration
    /// record.
    public init(format: VideoFormat, options: Options = Options()) throws {
        guard let id = format.codec.codecID, let codec = avcodec_find_decoder(id) else {
            throw VideoCodecError.unsupportedCodec(format.codec)
        }
        guard let packet = av_packet_alloc() else { throw VideoCodecError.ffmpeg(cffmpeg_error_again()) }
        guard let frame = av_frame_alloc() else {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
            throw VideoCodecError.ffmpeg(cffmpeg_error_again())
        }
        self.format = format
        self.options = options
        self.codec = codec
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
        guard let context = avcodec_alloc_context3(codec) else { throw VideoCodecError.unsupportedCodec(format.codec) }
        context.pointee.width = Int32(clamping: format.width)
        context.pointee.height = Int32(clamping: format.height)
        context.pointee.thread_count = Int32(clamping: options.threadCount)
        context.pointee.pkt_timebase = AVRational(num: 1, den: timescale)
        if !format.configuration.isEmpty {
            // libavcodec reads past the end: the padding is zeroed.
            let size = format.configuration.count
            guard let extradata = av_mallocz(size + Int(cffmpeg_input_padding()))?.assumingMemoryBound(to: UInt8.self) else {
                var context: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&context)
                throw VideoCodecError.ffmpeg(cffmpeg_error_again())
            }
            format.configuration.withUnsafeBufferPointer { extradata.update(from: $0.baseAddress!, count: size) }
            context.pointee.extradata = extradata
            context.pointee.extradata_size = Int32(size)
        }
        let result = avcodec_open2(context, codec, nil)
        guard result >= 0 else {
            var context: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&context)
            throw VideoCodecError.ffmpeg(result)
        }
        self.context = context
        self.timescale = timescale
        return context
    }

    /// Decodes a sample of coded video: the pictures that became ready, in
    /// presentation order, perhaps none yet.
    public func decode(_ sample: SampleBuffer) throws -> [SampleBuffer] {
        guard let data = sample.data, !data.isEmpty else { throw VideoCodecError.noData }
        let timing = sample.timing
        let scale = timescale > 0 ? timescale
            : timing.presentationTime.isNumeric ? timing.presentationTime.timescale
            : timing.decodeTime.isNumeric ? timing.decodeTime.timescale : 90_000
        let context = try open(timescale: scale)
        try check(av_new_packet(packet, Int32(clamping: data.count)))
        defer { av_packet_unref(packet) }
        data.withUnsafeBytes { bytes in
            packet.pointee.data.update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        packet.pointee.pts = timing.presentationTime.timestamp(in: scale)
        packet.pointee.dts = timing.decodeTime.timestamp(in: scale)
        packet.pointee.duration = timing.duration.isNumeric ? timing.duration.timestamp(in: scale) : 0
        cffmpeg_packet_set_key(packet, sample.isSync ? 1 : 0)
        var pictures: [SampleBuffer] = []
        // A full decoder takes the packet once its pictures are taken.
        while true {
            let sent = avcodec_send_packet(context, packet)
            if sent == cffmpeg_error_again() {
                let taken = try receive(from: context)
                pictures += taken
                if taken.isEmpty { throw VideoCodecError.ffmpeg(sent) }
                continue
            }
            try check(sent)
            break
        }
        return pictures + (try receive(from: context))
    }

    /// The pictures still held, once there are no more samples. The decoder
    /// then starts over, for samples after a seek.
    public func finish() throws -> [SampleBuffer] {
        guard let context else { return [] }
        try check(avcodec_send_packet(context, nil))
        let pictures = try receive(from: context)
        avcodec_flush_buffers(context)
        return pictures
    }

    /// Drops the samples and pictures held, as after a seek.
    public func reset() {
        guard let context else { return }
        avcodec_flush_buffers(context)
    }

    /// Every picture ready.
    private func receive(from context: UnsafeMutablePointer<AVCodecContext>) throws -> [SampleBuffer] {
        var pictures: [SampleBuffer] = []
        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == cffmpeg_error_again() || received == cffmpeg_error_eof() { return pictures }
            try check(received)
            defer { av_frame_unref(frame) }
            pictures.append(try picture(from: frame))
        }
    }

    /// A decoded frame as a sample buffer over a reference to its pixels.
    private func picture(from frame: UnsafeMutablePointer<AVFrame>) throws -> SampleBuffer {
        let ffmpegFormat = AVPixelFormat(rawValue: frame.pointee.format)
        guard let pixelFormat = PixelFormat(ffmpeg: ffmpegFormat) else {
            throw VideoCodecError.unsupportedPixelFormat(name(of: ffmpegFormat))
        }
        guard let reference = av_frame_clone(frame) else { throw VideoCodecError.ffmpeg(cffmpeg_error_again()) }
        var planes: [(base: UnsafeMutableRawPointer, bytesPerRow: Int)] = []
        withUnsafeBytes(of: reference.pointee.data) { data in
            withUnsafeBytes(of: reference.pointee.linesize) { linesize in
                for index in pixelFormat.planes.indices {
                    let pointer = data.load(fromByteOffset: index * MemoryLayout<UnsafeMutablePointer<UInt8>?>.stride,
                                            as: UnsafeMutablePointer<UInt8>?.self)
                    let stride = linesize.load(fromByteOffset: index * MemoryLayout<Int32>.stride, as: Int32.self)
                    guard let pointer else { continue }
                    planes.append((UnsafeMutableRawPointer(pointer), Int(stride)))
                }
            }
        }
        let address = UInt(bitPattern: reference)
        let release: @Sendable () -> Void = {
            var frame = UnsafeMutablePointer<AVFrame>(bitPattern: address)
            av_frame_free(&frame)
        }
        guard planes.count == pixelFormat.planes.count, planes.allSatisfy({ $0.bytesPerRow > 0 }) else {
            release()
            throw VideoCodecError.unsupportedPixelFormat(name(of: ffmpegFormat))
        }
        let pixels = PixelBuffer(
            width: Int(reference.pointee.width),
            height: Int(reference.pointee.height),
            format: pixelFormat,
            color: ColorInfo(frame: reference),
            planesNoCopy: planes,
            release: release
        )
        let timestamp = reference.pointee.best_effort_timestamp != cffmpeg_no_timestamp()
            ? reference.pointee.best_effort_timestamp : reference.pointee.pts
        let duration = reference.pointee.duration > 0 ? MediaTime(value: reference.pointee.duration, timescale: timescale) : .invalid
        var pictureFormat = format
        (pictureFormat.width, pictureFormat.height, pictureFormat.color) = (pixels.width, pixels.height, pixels.color)
        return SampleBuffer(
            image: pixels,
            format: .video(pictureFormat),
            timing: SampleTiming(presentationTime: MediaTime(timestamp: timestamp, timescale: timescale), duration: duration),
            flags: cffmpeg_frame_is_key(reference) != 0 ? .sync : []
        )
    }
}
