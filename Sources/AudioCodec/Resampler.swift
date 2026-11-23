import CFFmpeg
import CFFmpegResample

/// Converts PCM between sample formats, rates and channel counts, on
/// libswresample, which holds back a few frames as it filters.
final class Resampler {

    /// PCM as libswresample sees it.
    struct Format: Equatable {
        var sampleFormat: AVSampleFormat
        var sampleRate: Int32
        var channelCount: Int32

        var isPlanar: Bool { av_sample_fmt_is_planar(sampleFormat) != 0 }

        var bytesPerSample: Int { Int(av_get_bytes_per_sample(sampleFormat)) }

        /// Planes the samples are in: one when interleaved.
        var planeCount: Int { isPlanar ? Int(channelCount) : 1 }

        /// The bytes a frame takes in each plane.
        var bytesPerFramePerPlane: Int { isPlanar ? bytesPerSample : bytesPerSample * Int(channelCount) }
    }

    let input: Format

    let output: Format

    private var context: OpaquePointer?

    /// A resampler from `input`, whose channels are in `inputLayout`, or
    /// the usual order for their count, to `output`'s usual order.
    init(from input: Format, to output: Format, inputLayout: UnsafePointer<AVChannelLayout>? = nil) throws {
        var inLayout = AVChannelLayout()
        var outLayout = AVChannelLayout()
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }
        if let inputLayout, inputLayout.pointee.nb_channels == input.channelCount {
            try check(av_channel_layout_copy(&inLayout, inputLayout))
        } else {
            av_channel_layout_default(&inLayout, input.channelCount)
        }
        av_channel_layout_default(&outLayout, output.channelCount)
        var context: OpaquePointer?
        try check(swr_alloc_set_opts2(&context, &outLayout, output.sampleFormat, output.sampleRate,
                                      &inLayout, input.sampleFormat, input.sampleRate, 0, nil))
        let initialized = swr_init(context)
        guard initialized >= 0 else {
            swr_free(&context)
            throw AudioCodecError.ffmpeg(initialized)
        }
        self.input = input
        self.output = output
        self.context = context
    }

    deinit {
        swr_free(&context)
    }

    /// The frames held back, at the output's rate.
    var delay: Int64 {
        swr_get_delay(context, Int64(output.sampleRate))
    }

    /// Converts `frames` frames from the input's planes, or with none, the
    /// frames held back: the output's planes back to back, each `frames`
    /// long.
    func convert(_ planes: [UnsafePointer<UInt8>?], frames: Int) throws -> (bytes: [UInt8], frames: Int) {
        let capacity = Int(try check(swr_get_out_samples(context, Int32(clamping: frames))))
        guard capacity > 0 else { return ([], 0) }
        let planeSize = capacity * output.bytesPerFramePerPlane
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: planeSize * output.planeCount, alignment: 32)
        defer { buffer.deallocate() }
        var outputs: [UnsafeMutablePointer<UInt8>?] = (0..<output.planeCount).map {
            buffer.baseAddress!.advanced(by: $0 * planeSize).assumingMemoryBound(to: UInt8.self)
        }
        let converted: Int32
        if planes.isEmpty {
            converted = swr_convert(context, &outputs, Int32(capacity), nil, 0)
        } else {
            var inputs = planes
            converted = swr_convert(context, &outputs, Int32(capacity), &inputs, Int32(clamping: frames))
        }
        let count = Int(try check(converted))
        let used = count * output.bytesPerFramePerPlane
        var bytes: [UInt8] = []
        bytes.reserveCapacity(used * output.planeCount)
        for plane in 0..<output.planeCount {
            bytes += UnsafeRawBufferPointer(start: buffer.baseAddress!.advanced(by: plane * planeSize), count: used)
        }
        return (bytes, count)
    }
}
