/// A decoded picture, which a sample buffer can carry in place of bytes.
/// PixelBuffers' `PixelBuffer` is one.
public protocol MediaImage: AnyObject, Sendable {

    /// The picture's size in pixels.
    var width: Int { get }

    var height: Int { get }

    var color: ColorInfo { get }
}

/// When a sample shows, when it decodes, and how long it lasts.
public struct SampleTiming: Hashable, Sendable {

    /// When it shows.
    public var presentationTime: MediaTime

    /// When it must be decoded, which is earlier than it shows for frames
    /// that others depend on; invalid when it's the presentation time.
    public var decodeTime: MediaTime

    /// How long it lasts; invalid when unknown.
    public var duration: MediaTime

    public init(presentationTime: MediaTime, decodeTime: MediaTime = .invalid, duration: MediaTime = .invalid) {
        self.presentationTime = presentationTime
        self.decodeTime = decodeTime
        self.duration = duration
    }

    /// The decode time, or the presentation time where there is none.
    public var effectiveDecodeTime: MediaTime {
        decodeTime.isValid ? decodeTime : presentationTime
    }
}

/// What a sample is to the samples around it.
public struct SampleFlags: OptionSet, Hashable, Sendable {

    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// It decodes without the samples before it: a keyframe, a point to
    /// seek to.
    public static let sync = SampleFlags(rawValue: 1 << 0)

    /// No other sample depends on it, so it can be dropped.
    public static let droppable = SampleFlags(rawValue: 1 << 1)

    /// It isn't to be shown, only decoded for those that follow.
    public static let doNotDisplay = SampleFlags(rawValue: 1 << 2)

    /// The samples before it don't run on to it: after a seek, or a gap.
    public static let discontinuity = SampleFlags(rawValue: 1 << 3)
}

/// One or more samples of a track: their bytes or the picture they
/// decoded to, what they are, and when.
///
/// A video sample buffer is one frame. An audio one may hold many frames of
/// PCM, or several packets of coded audio, back to back: `sampleCount` of
/// them from `timing`, each `sampleSizes` long when they differ.
public struct SampleBuffer: Sendable {

    /// What the samples are made of.
    public enum Content: Sendable {
        /// Bytes: coded video, coded or PCM audio, text.
        case data(BlockBuffer)
        /// A decoded picture.
        case image(any MediaImage)
        /// Nothing: a marker, such as the end of a track, carrying only
        /// timing and flags.
        case empty
    }

    public var content: Content

    /// What the samples are; nil for a marker.
    public var format: FormatDescription?

    /// The first sample's timing; the duration is all the samples'.
    public var timing: SampleTiming

    public var sampleCount: Int

    /// Each sample's size in bytes, when the samples are bytes and their
    /// sizes differ; empty when there's one sample, or all are the same
    /// size.
    public var sampleSizes: [Int]

    public var flags: SampleFlags

    public init(
        content: Content,
        format: FormatDescription?,
        timing: SampleTiming,
        sampleCount: Int = 1,
        sampleSizes: [Int] = [],
        flags: SampleFlags = []
    ) {
        self.content = content
        self.format = format
        self.timing = timing
        self.sampleCount = sampleCount
        self.sampleSizes = sampleSizes
        self.flags = flags
    }

    /// One sample of bytes.
    public init(data: BlockBuffer, format: FormatDescription?, timing: SampleTiming, flags: SampleFlags = []) {
        self.init(content: .data(data), format: format, timing: timing, flags: flags)
    }

    /// A decoded picture.
    public init(image: any MediaImage, format: FormatDescription?, timing: SampleTiming, flags: SampleFlags = []) {
        self.init(content: .image(image), format: format, timing: timing, flags: flags)
    }

    /// The samples' bytes, or nil for a picture or a marker.
    public var data: BlockBuffer? {
        if case .data(let data) = content { return data }
        return nil
    }

    /// The decoded picture, or nil for bytes or a marker.
    public var image: (any MediaImage)? {
        if case .image(let image) = content { return image }
        return nil
    }

    public var presentationTime: MediaTime { timing.presentationTime }

    public var duration: MediaTime { timing.duration }

    /// When the samples show, from the first's presentation time for their
    /// duration; invalid when the duration isn't known.
    public var presentationTimeRange: MediaTimeRange {
        guard timing.presentationTime.isValid, timing.duration.isValid else { return .invalid }
        return MediaTimeRange(start: timing.presentationTime, duration: timing.duration)
    }

    /// Whether it decodes on its own.
    public var isSync: Bool { flags.contains(.sync) }

    /// Each sample's bytes, sharing this buffer's memory: from
    /// `sampleSizes`, or split evenly; empty for a picture or a marker.
    public var samples: [BlockBuffer] {
        guard let data else { return [] }
        guard sampleCount > 1 else { return [data] }
        let sizes = sampleSizes.count == sampleCount ? sampleSizes : Array(repeating: data.count / sampleCount, count: sampleCount)
        var offset = 0
        var samples: [BlockBuffer] = []
        samples.reserveCapacity(sizes.count)
        for size in sizes where offset + size <= data.count {
            samples.append(data[offset..<offset + size])
            offset += size
        }
        return samples
    }
}
