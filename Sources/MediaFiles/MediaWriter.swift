import CFFmpegFormat
import MediaCore

/// Writes tracks of sample buffers to a media file, on libavformat: MP4,
/// MOV, Matroska and WebM, MPEG-TS, Ogg, WAV, and the rest FFmpeg can write.
///
/// Add every track, then write samples, each in decode order within its
/// track; libavformat interleaves the tracks. `finish` completes the file.
/// A writer is for one thread at a time.
public final class MediaWriter {

    /// Where it writes.
    public let url: String

    /// The container's name, as FFmpeg calls it: "mp4", "matroska".
    public let container: String

    private var context: UnsafeMutablePointer<AVFormatContext>?

    private var started = false

    private var finished = false

    /// Each track's scale, which its samples' times are converted from.
    private var timescales: [Int32] = []

    /// Each track's last decode timestamp, in its stream's time base.
    private var lastDecodeTimestamps: [Int64?] = []

    /// A writer for `url`, in the container named or, by default, the one
    /// its extension says.
    public init(url: String, container: String? = nil) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let made = avformat_alloc_output_context2(&context, nil, container, url)
        guard made >= 0, let context, let format = context.pointee.oformat else {
            throw MediaFilesError.unknownContainer(container ?? url)
        }
        self.url = url
        self.context = context
        self.container = format.pointee.name.map { String(cString: $0) } ?? container ?? ""
    }

    deinit {
        guard let context else { return }
        if started, !finished { av_write_trailer(context) }
        if let format = context.pointee.oformat, cffmpeg_format_needs_file(format) != 0 { avio_closep(&context.pointee.pb) }
        avformat_free_context(context)
    }

    /// Adds a track of `format`, timed in `timescale`: its ID, which samples
    /// are written with. Tracks are added before any sample.
    @discardableResult
    public func addTrack(_ format: FormatDescription, timescale: Int32, language: String? = nil, isDefault: Bool = false) throws -> Int {
        guard let context, !finished else { throw MediaFilesError.finished }
        guard !started else { throw MediaFilesError.alreadyWriting }
        guard timescale > 0 else { throw MediaFilesError.unsupportedFormat("timescale \(timescale)") }
        // The format is checked before the stream is made, which can't be
        // taken back.
        var parameters = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parameters) }
        guard let parameters else { throw MediaFilesError.ffmpeg(cffmpeg_format_error_again()) }
        try format.apply(to: parameters)
        guard let stream = avformat_new_stream(context, nil) else { throw MediaFilesError.ffmpeg(cffmpeg_format_error_again()) }
        try check(avcodec_parameters_copy(stream.pointee.codecpar, parameters))
        stream.pointee.time_base = AVRational(num: 1, den: timescale)
        if let language { av_dict_set(&stream.pointee.metadata, "language", language, 0) }
        if isDefault { stream.pointee.disposition |= AV_DISPOSITION_DEFAULT }
        timescales.append(timescale)
        lastDecodeTimestamps.append(nil)
        return Int(stream.pointee.index)
    }

    /// Opens the file and writes the container's header, once.
    private func start() throws -> UnsafeMutablePointer<AVFormatContext> {
        guard let context, !finished else { throw MediaFilesError.finished }
        guard !started else { return context }
        if let format = context.pointee.oformat, cffmpeg_format_needs_file(format) != 0 {
            let opened = avio_open(&context.pointee.pb, url, cffmpeg_format_write_flag())
            guard opened >= 0 else { throw MediaFilesError.cannotOpen(url, message: MediaFilesError.describe(opened)) }
        }
        try check(avformat_write_header(context, nil))
        started = true
        return context
    }

    /// Writes a sample of a track; its bytes are copied.
    public func write(_ sample: SampleBuffer, to track: Int) throws {
        guard timescales.indices.contains(track) else { throw MediaFilesError.noSuchTrack(track) }
        let context = try start()
        guard let data = sample.data, let stream = context.pointee.streams[track] else { return }
        // The muxer may have changed the stream's time base.
        let timeBase = stream.pointee.time_base
        guard let packet = av_packet_alloc() else { throw MediaFilesError.ffmpeg(cffmpeg_format_error_again()) }
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        try check(av_new_packet(packet, Int32(clamping: data.count)))
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            packet.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        let timing = sample.timing
        packet.pointee.stream_index = Int32(track)
        packet.pointee.pts = timing.presentationTime.timestamp(in: timeBase)
        packet.pointee.dts = timing.effectiveDecodeTime.timestamp(in: timeBase)
        let decode = packet.pointee.dts
        if timing.duration.isNumeric {
            packet.pointee.duration = timing.duration.timestamp(in: timeBase)
        } else if decode != cffmpeg_format_no_timestamp(), let last = lastDecodeTimestamps[track], last < decode {
            // A sample without one lasts as long as the one before: MP4
            // drops a last sample with no duration.
            packet.pointee.duration = decode - last
        }
        if decode != cffmpeg_format_no_timestamp() { lastDecodeTimestamps[track] = decode }
        cffmpeg_format_packet_set_key(packet, sample.isSync ? 1 : 0)
        // Interleaved: libavformat orders the tracks' samples, and takes the
        // packet's bytes.
        try check(av_interleaved_write_frame(context, packet))
    }

    /// Writes what's still held and the container's end, and closes the
    /// file. A file with no samples gets its header too.
    public func finish() throws {
        guard !finished else { return }
        let context = try start()
        finished = true
        try check(av_write_trailer(context))
        if let format = context.pointee.oformat, cffmpeg_format_needs_file(format) != 0 { try check(avio_closep(&context.pointee.pb)) }
    }
}
