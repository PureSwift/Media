import CFFmpeg
import MediaCore
import PixelBuffers

/// Encodes pictures to coded video, on libavcodec.
///
/// Give it pictures of its size and pixel format in presentation order;
/// each `encode` returns the samples that became ready, in decode order,
/// perhaps none yet, and `finish` returns the rest. `format` describes them,
/// with the encoder's configuration record when the codec has one, as a
/// file's track or a decoder needs. An encoder is for one thread at a time.
public final class VideoEncoder {

    /// What to encode and how.
    public struct Settings: Sendable {

        public var codec: CodecType

        public var width: Int

        public var height: Int

        /// The pictures' pixel format, which the codec must take.
        public var pixelFormat: PixelFormat

        /// The scale of the presentation times it's given.
        public var timescale: Int32

        public var color: ColorInfo

        /// Bits a second to aim for; nil for the codec's default.
        public var bitRate: Int?

        /// The most pictures from one keyframe to the next; nil for the
        /// codec's default.
        public var keyframeInterval: Int?

        /// Whether pictures may be reordered (B-frames), which makes the
        /// decode order differ from the presentation order.
        public var allowsReordering: Bool

        /// Threads to encode with: 0 lets libavcodec choose.
        public var threadCount: Int

        public init(
            codec: CodecType,
            width: Int,
            height: Int,
            pixelFormat: PixelFormat = .i420,
            timescale: Int32,
            color: ColorInfo = .bt709,
            bitRate: Int? = nil,
            keyframeInterval: Int? = nil,
            allowsReordering: Bool = false,
            threadCount: Int = 0
        ) {
            self.codec = codec
            self.width = width
            self.height = height
            self.pixelFormat = pixelFormat
            self.timescale = timescale
            self.color = color
            self.bitRate = bitRate
            self.keyframeInterval = keyframeInterval
            self.allowsReordering = allowsReordering
            self.threadCount = threadCount
        }
    }

    public let settings: Settings

    /// What it encodes to: the codec, size and color, and its
    /// configuration record (an `avcC` for H.264), from libavcodec.
    public let format: VideoFormat

    private let context: UnsafeMutablePointer<AVCodecContext>

    private let frame: UnsafeMutablePointer<AVFrame>

    private let packet: UnsafeMutablePointer<AVPacket>

    private let ffmpegFormat: AVPixelFormat

    public init(settings: Settings) throws {
        guard let id = settings.codec.codecID, let codec = avcodec_find_encoder(id) else {
            throw VideoCodecError.unsupportedCodec(settings.codec)
        }
        guard let ffmpegFormat = settings.pixelFormat.ffmpegFormat else {
            throw VideoCodecError.unsupportedPixelFormat(settings.pixelFormat.name)
        }
        guard let context = avcodec_alloc_context3(codec) else { throw VideoCodecError.unsupportedCodec(settings.codec) }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        context.pointee.width = Int32(clamping: settings.width)
        context.pointee.height = Int32(clamping: settings.height)
        context.pointee.pix_fmt = ffmpegFormat
        context.pointee.time_base = AVRational(num: 1, den: settings.timescale)
        context.pointee.thread_count = Int32(clamping: settings.threadCount)
        if let bitRate = settings.bitRate { context.pointee.bit_rate = Int64(bitRate) }
        if let interval = settings.keyframeInterval { context.pointee.gop_size = Int32(clamping: interval) }
        if !settings.allowsReordering { context.pointee.max_b_frames = 0 }
        settings.color.apply(to: context)
        // Parameter sets in the configuration record, as MP4 keeps them.
        cffmpeg_context_set_global_header(context)
        let opened = avcodec_open2(context, codec, nil)
        guard opened >= 0 else {
            avcodec_free_context(&owned)
            throw VideoCodecError.ffmpeg(opened)
        }
        guard let frame = av_frame_alloc(), let packet = av_packet_alloc() else {
            avcodec_free_context(&owned)
            throw VideoCodecError.ffmpeg(cffmpeg_error_again())
        }
        var configuration: [UInt8] = []
        if let extradata = context.pointee.extradata, context.pointee.extradata_size > 0 {
            configuration = Array(UnsafeBufferPointer(start: extradata, count: Int(context.pointee.extradata_size)))
        }
        self.settings = settings
        self.context = context
        self.frame = frame
        self.packet = packet
        self.ffmpegFormat = ffmpegFormat
        self.format = VideoFormat(codec: settings.codec, width: settings.width, height: settings.height, color: settings.color,
                                  configuration: configuration)
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
    }

    /// Encodes a picture shown at `presentationTime`: the samples that
    /// became ready, perhaps none yet. `keyframe` makes it one.
    public func encode(_ picture: PixelBuffer, presentationTime: MediaTime, keyframe: Bool = false) throws -> [SampleBuffer] {
        guard picture.width == settings.width, picture.height == settings.height, picture.format == settings.pixelFormat,
              picture.isInMemory else {
            throw VideoCodecError.mismatchedPicture
        }
        frame.pointee.format = ffmpegFormat.rawValue
        frame.pointee.width = Int32(clamping: picture.width)
        frame.pointee.height = Int32(clamping: picture.height)
        try check(av_frame_get_buffer(frame, 0))
        defer { av_frame_unref(frame) }
        try copy(picture, into: frame)
        frame.pointee.pts = presentationTime.timestamp(in: settings.timescale)
        cffmpeg_frame_set_key(frame, keyframe ? 1 : 0)
        return try send(frame)
    }

    /// The samples still held, once there are no more pictures.
    public func finish() throws -> [SampleBuffer] {
        try send(nil)
    }

    private func send(_ frame: UnsafeMutablePointer<AVFrame>?) throws -> [SampleBuffer] {
        var samples: [SampleBuffer] = []
        while true {
            let sent = avcodec_send_frame(context, frame)
            if sent == cffmpeg_error_again() {
                let taken = try receive()
                samples += taken
                if taken.isEmpty { throw VideoCodecError.ffmpeg(sent) }
                continue
            }
            // Finishing twice is no error.
            if sent == cffmpeg_error_eof(), frame == nil { return samples }
            try check(sent)
            break
        }
        return samples + (try receive())
    }

    private func receive() throws -> [SampleBuffer] {
        var samples: [SampleBuffer] = []
        while true {
            let received = avcodec_receive_packet(context, packet)
            if received == cffmpeg_error_again() || received == cffmpeg_error_eof() { return samples }
            try check(received)
            defer { av_packet_unref(packet) }
            let bytes = BlockBuffer(bytes: UnsafeBufferPointer(start: packet.pointee.data, count: Int(packet.pointee.size)))
            let scale = settings.timescale
            let timing = SampleTiming(
                presentationTime: MediaTime(timestamp: packet.pointee.pts, timescale: scale),
                decodeTime: MediaTime(timestamp: packet.pointee.dts, timescale: scale),
                duration: packet.pointee.duration > 0 ? MediaTime(value: packet.pointee.duration, timescale: scale) : .invalid
            )
            samples.append(SampleBuffer(data: bytes, format: .video(format), timing: timing,
                                        flags: cffmpeg_packet_is_key(packet) != 0 ? .sync : []))
        }
    }

    /// Copies a picture's planes into libavcodec's frame, row by row, as
    /// their strides may differ.
    private func copy(_ picture: PixelBuffer, into frame: UnsafeMutablePointer<AVFrame>) throws {
        try check(av_frame_make_writable(frame))
        withUnsafeBytes(of: frame.pointee.data) { data in
            withUnsafeBytes(of: frame.pointee.linesize) { linesize in
                for (index, plane) in picture.planes.enumerated() {
                    guard let target = data.load(fromByteOffset: index * MemoryLayout<UnsafeMutablePointer<UInt8>?>.stride,
                                                 as: UnsafeMutablePointer<UInt8>?.self) else { continue }
                    let stride = Int(linesize.load(fromByteOffset: index * MemoryLayout<Int32>.stride, as: Int32.self))
                    let rowBytes = plane.width * picture.format.planes[index].bytesPerElement
                    picture.withPlane(index) { source in
                        for row in 0..<plane.height {
                            UnsafeMutableRawPointer(target + row * stride)
                                .copyMemory(from: source.baseAddress! + row * plane.bytesPerRow, byteCount: rowBytes)
                        }
                    }
                }
            }
        }
    }
}
