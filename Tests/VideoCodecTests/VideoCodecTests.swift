import MediaCore
import PixelBuffers
import Testing
import VideoCodec

/// Encodes pictures and decodes them again, with libavcodec's own codecs.
@Suite struct VideoCodecTests {

    /// A picture whose luma is a gradient moving with `frame`, and gray
    /// chroma.
    private func picture(width: Int, height: Int, frame: Int) -> PixelBuffer {
        let buffer = PixelBuffer(width: width, height: height, format: .i420, color: .bt709)
        buffer.withMutablePlane(0) { luma in
            for y in 0..<height {
                for x in 0..<width {
                    luma[y * buffer.planes[0].bytesPerRow + x] = UInt8(truncatingIfNeeded: 16 + (x * 2 + y + frame * 4) % 200)
                }
            }
        }
        return buffer
    }

    /// The average difference between two pictures' luma.
    private func lumaDifference(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        var total = 0
        a.withPlane(0) { first in
            b.withPlane(0) { second in
                for y in 0..<a.height {
                    for x in 0..<a.width {
                        total += abs(Int(first[y * a.planes[0].bytesPerRow + x]) - Int(second[y * b.planes[0].bytesPerRow + x]))
                    }
                }
            }
        }
        return Double(total) / Double(a.width * a.height)
    }

    /// Encodes `count` pictures and decodes what came out: the source
    /// pictures and the decoded samples.
    private func roundTrip(_ codec: CodecType, count: Int = 10) throws -> (sources: [PixelBuffer], decoded: [SampleBuffer], encoder: VideoEncoder) {
        let (width, height) = (64, 48)
        let encoder = try VideoEncoder(settings: VideoEncoder.Settings(
            codec: codec, width: width, height: height, timescale: 30, bitRate: 4_000_000, keyframeInterval: 5
        ))
        var sources: [PixelBuffer] = []
        var coded: [SampleBuffer] = []
        for index in 0..<count {
            let source = picture(width: width, height: height, frame: index)
            sources.append(source)
            coded += try encoder.encode(source, presentationTime: MediaTime(value: Int64(index), timescale: 30), keyframe: index == 0)
        }
        coded += try encoder.finish()
        let decoder = try VideoDecoder(format: encoder.format)
        var decoded: [SampleBuffer] = []
        for sample in coded {
            decoded += try decoder.decode(sample)
        }
        decoded += try decoder.finish()
        return (sources, decoded, encoder)
    }

    @Test func roundTripsMPEG4() throws {
        let (sources, decoded, encoder) = try roundTrip(.mpeg4Video)
        #expect(!encoder.format.configuration.isEmpty)
        #expect(decoded.count == sources.count)
        #expect(decoded.map(\.presentationTime) == (0..<sources.count).map { MediaTime(value: Int64($0), timescale: 30) })
        #expect(decoded.first?.isSync == true)
        for (source, sample) in zip(sources, decoded) {
            let image = try #require(sample.image as? PixelBuffer)
            #expect(image.width == 64 && image.height == 48)
            #expect(image.format == .i420)
            #expect(lumaDifference(source, image) < 6)
        }
        if case .video(let format)? = decoded.first?.format {
            #expect(format.codec == .mpeg4Video)
        } else {
            Issue.record("a decoded picture's format is video")
        }
    }

    @Test func roundTripsH264WhereThereIsAnEncoder() throws {
        do {
            let (sources, decoded, encoder) = try roundTrip(.h264)
            #expect(!encoder.format.configuration.isEmpty)
            #expect(decoded.count == sources.count)
            #expect(decoded.first?.isSync == true)
            let image = try #require(decoded.last?.image as? PixelBuffer)
            #expect(lumaDifference(sources.last!, image) < 6)
            // H.264 carries color in its stream.
            #expect(image.color.primaries == .bt709)
            #expect(image.color.matrix == .bt709)
        } catch VideoCodecError.unsupportedCodec {
            // No H.264 encoder here: nothing to round trip.
        }
    }

    @Test func refusesWhatItCantDo() throws {
        #expect(throws: VideoCodecError.unsupportedCodec("zzzz")) {
            try VideoDecoder(format: VideoFormat(codec: "zzzz", width: 16, height: 16))
        }
        let encoder = try VideoEncoder(settings: VideoEncoder.Settings(codec: .mpeg4Video, width: 32, height: 32, timescale: 30))
        #expect(throws: VideoCodecError.mismatchedPicture) {
            try encoder.encode(PixelBuffer(width: 16, height: 16, format: .i420), presentationTime: .zero)
        }
        #expect(throws: VideoCodecError.mismatchedPicture) {
            try encoder.encode(PixelBuffer(width: 32, height: 32, format: .nv12), presentationTime: .zero)
        }
        let decoder = try VideoDecoder(format: encoder.format)
        #expect(throws: VideoCodecError.noData) {
            try decoder.decode(SampleBuffer(content: .empty, format: nil, timing: SampleTiming(presentationTime: .zero)))
        }
        // Finishing before anything, and twice, gives nothing.
        #expect(try decoder.finish().isEmpty)
        #expect(try encoder.finish().isEmpty)
        #expect(try encoder.finish().isEmpty)
    }

    @Test func picturesOutliveTheirDecoder() throws {
        var kept: [SampleBuffer] = []
        do {
            let (_, decoded, _) = try roundTrip(.mpeg4Video, count: 3)
            kept = decoded
        }
        let image = try #require(kept.first?.image as? PixelBuffer)
        // libavcodec's frame is still there.
        #expect(image.withPlane(0) { $0.count } >= 64 * 48)
    }
}
