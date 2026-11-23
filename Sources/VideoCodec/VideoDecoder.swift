import CFFmpeg
import MediaCore
import PixelBuffers
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

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

        /// The device to decode on, when the codec can; libavcodec decodes
        /// in software when it can't, or there's no device.
        public var hardware: Hardware

        /// Whether hardware frames come as the dma-bufs they're in, to show
        /// without copying, or are copied into memory.
        public var exportsDMABuffers: Bool

        public init(threadCount: Int = 0, hardware: Hardware = .none, exportsDMABuffers: Bool = false) {
            self.threadCount = threadCount
            self.hardware = hardware
            self.exportsDMABuffers = exportsDMABuffers
        }
    }

    /// Hardware a decoder decodes on.
    public enum Hardware: Hashable, Sendable {
        case none
        /// VA-API, on a DRM render node: Intel and AMD GPUs, and others
        /// with a VA-API driver.
        case vaapi(device: String = "/dev/dri/renderD128")
    }

    /// Whether the last picture was decoded on the hardware asked for:
    /// false when the codec, or the profile, can't be, or the device
    /// couldn't be opened, and libavcodec decodes in software.
    public private(set) var isHardwareAccelerated = false

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
        if case .vaapi(let device) = options.hardware, cffmpeg_codec_has_vaapi(codec) != 0 {
            var hardware: UnsafeMutablePointer<AVBufferRef>?
            if av_hwdevice_ctx_create(&hardware, AV_HWDEVICE_TYPE_VAAPI, device, nil, 0) >= 0 {
                // The context takes the device's reference.
                context.pointee.hw_device_ctx = hardware
                cffmpeg_context_prefer_vaapi(context)
                // Pictures shown from their surfaces hold them: spares, so
                // a viewer can keep a few without stalling the decoder.
                if options.exportsDMABuffers { context.pointee.extra_hw_frames = 8 }
            }
        }
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

    /// A decoded frame as a sample buffer over a reference to its pixels:
    /// for a hardware frame, its dma-bufs, or a copy in memory.
    private func picture(from frame: UnsafeMutablePointer<AVFrame>) throws -> SampleBuffer {
        isHardwareAccelerated = frame.pointee.format == AV_PIX_FMT_VAAPI.rawValue
        guard isHardwareAccelerated else {
            return sample(of: try pixelsInMemory(frame), from: frame)
        }
        if options.exportsDMABuffers {
            return sample(of: try pixelsInDMABuffers(frame), from: frame)
        }
        guard let memory = av_frame_alloc() else { throw VideoCodecError.ffmpeg(cffmpeg_error_again()) }
        var owned: UnsafeMutablePointer<AVFrame>? = memory
        defer { av_frame_free(&owned) }
        try check(av_hwframe_transfer_data(memory, frame, 0))
        try check(av_frame_copy_props(memory, frame))
        return sample(of: try pixelsInMemory(memory), from: frame)
    }

    /// A frame in memory, its planes referenced, not copied.
    private func pixelsInMemory(_ frame: UnsafeMutablePointer<AVFrame>) throws -> PixelBuffer {
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
        return PixelBuffer(
            width: Int(reference.pointee.width),
            height: Int(reference.pointee.height),
            format: pixelFormat,
            color: ColorInfo(frame: reference),
            planesNoCopy: planes,
            release: release
        )
    }

    /// A hardware frame as the dma-bufs it's in. The mapping holds the
    /// frame's surface, so the decoder doesn't draw into it again until the
    /// pixel buffer goes.
    private func pixelsInDMABuffers(_ frame: UnsafeMutablePointer<AVFrame>) throws -> PixelBuffer {
        guard let mapped = av_frame_alloc() else { throw VideoCodecError.ffmpeg(cffmpeg_error_again()) }
        let address = UInt(bitPattern: mapped)
        let release: @Sendable () -> Void = {
            var frame = UnsafeMutablePointer<AVFrame>(bitPattern: address)
            av_frame_free(&frame)
        }
        mapped.pointee.format = AV_PIX_FMT_DRM_PRIME.rawValue
        let result = av_hwframe_map(mapped, frame, cffmpeg_hwframe_map_read())
        guard result >= 0, let descriptor = cffmpeg_drm_descriptor(mapped) else {
            release()
            throw VideoCodecError.ffmpeg(result < 0 ? result : cffmpeg_error_again())
        }
        var planes: [DMABuffer.Plane] = []
        var tenBit = false
        for layer in 0..<cffmpeg_drm_layer_count(descriptor) {
            let fourCC = FourCharacterCode(rawValue: cffmpeg_drm_layer_format(descriptor, layer).byteSwapped)
            // VA-API exports NV12 as one layer, or as R8 and GR88; P010 as
            // P010, or R16 and GR1616.
            if fourCC == "P010" || fourCC == "R16 " { tenBit = true }
            for plane in 0..<cffmpeg_drm_plane_count(descriptor, layer) {
                planes.append(DMABuffer.Plane(
                    fileDescriptor: cffmpeg_drm_plane_fd(descriptor, layer, plane),
                    offset: Int(cffmpeg_drm_plane_offset(descriptor, layer, plane)),
                    bytesPerRow: Int(cffmpeg_drm_plane_pitch(descriptor, layer, plane))
                ))
            }
        }
        let pixelFormat: PixelFormat = tenBit ? .p010 : .nv12
        guard planes.count == pixelFormat.planes.count else {
            release()
            throw VideoCodecError.unsupportedPixelFormat("\(planes.count) planes from VA-API")
        }
        // The pixel buffer closes its own descriptors; the mapping keeps its.
        for index in planes.indices {
            planes[index].fileDescriptor = dup(planes[index].fileDescriptor)
        }
        return PixelBuffer(
            width: Int(frame.pointee.width),
            height: Int(frame.pointee.height),
            format: pixelFormat,
            color: ColorInfo(frame: frame),
            dmaBuffer: DMABuffer(planes: planes, modifier: cffmpeg_drm_modifier(descriptor)),
            release: release
        )
    }

    /// A picture's sample buffer, timed and flagged as its frame.
    private func sample(of pixels: PixelBuffer, from frame: UnsafeMutablePointer<AVFrame>) -> SampleBuffer {
        let timestamp = frame.pointee.best_effort_timestamp != cffmpeg_no_timestamp()
            ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        let duration = frame.pointee.duration > 0 ? MediaTime(value: frame.pointee.duration, timescale: timescale) : .invalid
        var pictureFormat = format
        (pictureFormat.width, pictureFormat.height, pictureFormat.color) = (pixels.width, pixels.height, pixels.color)
        return SampleBuffer(
            image: pixels,
            format: .video(pictureFormat),
            timing: SampleTiming(presentationTime: MediaTime(timestamp: timestamp, timescale: timescale), duration: duration),
            flags: cffmpeg_frame_is_key(frame) != 0 ? .sync : []
        )
    }
}
