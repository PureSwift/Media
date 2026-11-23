import CFFmpegFormat
import MediaCore

/// Reads a media file or stream's tracks, as sample buffers, on
/// libavformat: MP4, Matroska and WebM, MPEG-TS, HLS, Ogg, WAV, and the rest
/// FFmpeg knows, from a path or a URL.
///
/// `nextSample` reads the selected tracks' samples in the order the file
/// interleaves them, which is decode order within each track. Each sample's
/// bytes are libavformat's packet, wrapped, not copied. A reader is for one
/// thread at a time.
public final class MediaReader {

    /// One of the file's tracks.
    public struct Track: Hashable, Sendable {

        /// Its number in the file, which samples are read with.
        public var id: Int

        public var format: FormatDescription

        /// The scale the file times its samples in.
        public var timescale: Int32

        /// How long it lasts; invalid when the file doesn't say.
        public var duration: MediaTime

        /// Its language, as an ISO 639-2 code, when the file names one.
        public var language: String?

        /// Whether the file marks it as the one to play by default.
        public var isDefault: Bool
    }

    /// Where the file is.
    public let url: String

    /// The tracks this library can describe, in the file's order.
    public let tracks: [Track]

    /// How long the file lasts; invalid when it doesn't say, as a live
    /// stream doesn't.
    public let duration: MediaTime

    private var context: UnsafeMutablePointer<AVFormatContext>?

    private let packet: UnsafeMutablePointer<AVPacket>

    /// The tracks read; not every demuxer skips the others itself.
    private var selected: Set<Int>

    /// Opens and probes a file or stream: a path, or a URL in any protocol
    /// FFmpeg has (file, http, https, hls…).
    public init(url: String) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, url, nil, nil)
        guard opened >= 0, let context else { throw MediaFilesError.cannotOpen(url, message: MediaFilesError.describe(opened)) }
        let probed = avformat_find_stream_info(context, nil)
        guard probed >= 0, let packet = av_packet_alloc() else {
            var owned: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&owned)
            throw MediaFilesError.cannotOpen(url, message: MediaFilesError.describe(probed))
        }
        var tracks: [Track] = []
        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index], let parameters = stream.pointee.codecpar,
                  let format = FormatDescription(parameters: parameters) else { continue }
            let timeBase = stream.pointee.time_base
            let language = av_dict_get(stream.pointee.metadata, "language", nil, 0).flatMap { $0.pointee.value }.map { String(cString: $0) }
            tracks.append(Track(
                id: index,
                format: format,
                timescale: timeBase.den,
                duration: stream.pointee.duration > 0 ? MediaTime(timestamp: stream.pointee.duration, timeBase: timeBase) : .invalid,
                language: language == "und" ? nil : language,
                isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0
            ))
        }
        self.url = url
        self.context = context
        self.packet = packet
        self.tracks = tracks
        self.selected = Set(tracks.map(\.id))
        self.duration = context.pointee.duration > 0
            ? MediaTime(value: context.pointee.duration, timescale: Int32(AV_TIME_BASE)) : .invalid
        // Only the tracks described are read.
        let described = Set(tracks.map(\.id))
        for index in 0..<Int(context.pointee.nb_streams) where !described.contains(index) {
            context.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
    }

    deinit {
        avformat_close_input(&context)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
    }

    /// The track with an ID.
    public func track(_ id: Int) -> Track? {
        tracks.first { $0.id == id }
    }

    /// Reads only these tracks from now on; the others' samples are
    /// skipped.
    public func select(tracks ids: Set<Int>) throws {
        guard let context else { return }
        for id in ids where track(id) == nil { throw MediaFilesError.noSuchTrack(id) }
        for track in tracks {
            context.pointee.streams[track.id]?.pointee.discard = ids.contains(track.id) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
        selected = ids
    }

    /// The next sample of a selected track, with the track's ID; nil at the
    /// end of the file.
    public func nextSample() throws -> (track: Int, sample: SampleBuffer)? {
        guard let context else { return nil }
        while true {
            let read = av_read_frame(context, packet)
            if read == cffmpeg_format_error_eof() { return nil }
            try check(read)
            let index = Int(packet.pointee.stream_index)
            guard selected.contains(index), let track = track(index), let stream = context.pointee.streams[index] else {
                av_packet_unref(packet)
                continue
            }
            return (index, sample(of: track, timeBase: stream.pointee.time_base))
        }
    }

    /// The packet read, as a sample over its bytes, which the sample now
    /// owns.
    private func sample(of track: Track, timeBase: AVRational) -> SampleBuffer {
        var flags: SampleFlags = []
        if cffmpeg_format_packet_is_key(packet) != 0 { flags.insert(.sync) }
        if cffmpeg_format_packet_is_discarded(packet) != 0 { flags.insert(.doNotDisplay) }
        let timing = SampleTiming(
            presentationTime: MediaTime(timestamp: packet.pointee.pts, timeBase: timeBase),
            decodeTime: MediaTime(timestamp: packet.pointee.dts, timeBase: timeBase),
            duration: packet.pointee.duration > 0 ? MediaTime(timestamp: packet.pointee.duration, timeBase: timeBase) : .invalid
        )
        // The packet's reference moves to one the bytes keep.
        let bytes: BlockBuffer
        if packet.pointee.size > 0, let data = packet.pointee.data, let owned = av_packet_alloc() {
            av_packet_move_ref(owned, packet)
            let address = UInt(bitPattern: owned)
            bytes = BlockBuffer(bytesNoCopy: UnsafeRawBufferPointer(start: data, count: Int(owned.pointee.size))) {
                var packet = UnsafeMutablePointer<AVPacket>(bitPattern: address)
                av_packet_free(&packet)
            }
        } else {
            bytes = BlockBuffer()
            av_packet_unref(packet)
        }
        return SampleBuffer(data: bytes, format: track.format, timing: timing, flags: flags)
    }

    /// Moves to the keyframe at or before `time`, so that the samples read
    /// next decode from there.
    public func seek(to time: MediaTime) throws {
        guard let context, time.isNumeric else { return }
        let timestamp = time.timestamp(in: AVRational(num: 1, den: Int32(AV_TIME_BASE)))
        try check(av_seek_frame(context, -1, timestamp, cffmpeg_format_seek_backward()))
    }
}
