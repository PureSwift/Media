import Foundation
import MediaCore
import MediaFiles
import PixelBuffers
import Testing
import VideoCodec

/// Writes encoded pictures to files and reads them back, through
/// libavformat's own containers.
@Suite struct MediaFilesTests {

    private static let (width, height) = (64, 48)

    /// A picture whose luma is a gradient moving with `frame`.
    private func picture(frame: Int) -> PixelBuffer {
        let buffer = PixelBuffer(width: Self.width, height: Self.height, format: .i420, color: .bt709)
        buffer.withMutablePlane(0) { luma in
            for y in 0..<Self.height {
                for x in 0..<Self.width {
                    luma[y * buffer.planes[0].bytesPerRow + x] = UInt8(truncatingIfNeeded: 16 + (x * 2 + y + frame * 4) % 200)
                }
            }
        }
        return buffer
    }

    /// `count` pictures, encoded at 30 a second, a keyframe every five.
    private func encoded(_ codec: CodecType = .mpeg4Video, count: Int = 10) throws -> (format: VideoFormat, samples: [SampleBuffer]) {
        let encoder = try VideoEncoder(settings: VideoEncoder.Settings(
            codec: codec, width: Self.width, height: Self.height, timescale: 30, bitRate: 4_000_000, keyframeInterval: 5
        ))
        var samples: [SampleBuffer] = []
        for index in 0..<count {
            samples += try encoder.encode(picture(frame: index), presentationTime: MediaTime(value: Int64(index), timescale: 30), keyframe: index == 0)
        }
        samples += try encoder.finish()
        return (encoder.format, samples)
    }

    /// A path in a directory of its own, removed after `body`.
    private func withTemporaryFile<T>(named name: String, _ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory.appendingPathComponent(name).path)
    }

    /// Every sample a reader has left, with its track.
    private func readAll(_ reader: MediaReader) throws -> [(track: Int, sample: SampleBuffer)] {
        var samples: [(track: Int, sample: SampleBuffer)] = []
        while let next = try reader.nextSample() { samples.append(next) }
        return samples
    }

    /// A time in whole milliseconds, as Matroska stores it.
    private func milliseconds(_ time: MediaTime) -> Int {
        Int((time.seconds * 1000).rounded())
    }

    /// Ten pictures' times at 30 a second, in milliseconds.
    private let frameTimes = (0..<10).map { Int((Double($0) * 1000 / 30).rounded()) }

    /// Writes ten pictures to a file, reads them back and decodes them.
    private func roundTrip(fileName: String, codec: CodecType = .mpeg4Video) throws {
        let (format, written) = try encoded(codec)
        try withTemporaryFile(named: fileName) { path in
            let writer = try MediaWriter(url: path)
            let track = try writer.addTrack(.video(format), timescale: 30, language: "eng")
            for sample in written { try writer.write(sample, to: track) }
            try writer.finish()

            let reader = try MediaReader(url: path)
            try #require(reader.tracks.count == 1)
            let read = reader.tracks[0]
            #expect(read.language == "eng")
            guard case .video(let readFormat) = read.format else {
                Issue.record("the track is video")
                return
            }
            #expect(readFormat.codec == codec)
            #expect(readFormat.width == Self.width && readFormat.height == Self.height)
            #expect(!readFormat.configuration.isEmpty)
            #expect(abs(reader.duration.seconds - 10.0 / 30) < 0.05)

            let samples = try readAll(reader)
            #expect(samples.count == written.count)
            #expect(samples.allSatisfy { $0.track == read.id })
            #expect(samples.first?.sample.isSync == true)
            #expect(samples.map(\.sample.isSync) == written.map(\.isSync))
            if codec != .h264 {
                // Containers store H.264 length-prefixed, not as the encoder's
                // start codes; other codecs' bytes are kept as they are.
                #expect(samples.map { $0.sample.data?.bytes ?? [] } == written.map { $0.data?.bytes ?? [] })
            }
            #expect(Set(samples.map { milliseconds($0.sample.presentationTime) }) == Set(frameTimes))

            let decoder = try VideoDecoder(format: readFormat)
            var decoded: [SampleBuffer] = []
            for (_, sample) in samples { decoded += try decoder.decode(sample) }
            decoded += try decoder.finish()
            #expect(decoded.count == written.count)
            #expect(decoded.map { milliseconds($0.presentationTime) } == frameTimes)
        }
    }

    @Test func roundTripsMP4() throws {
        try roundTrip(fileName: "pictures.mp4")
    }

    @Test func roundTripsMatroska() throws {
        try roundTrip(fileName: "pictures.mkv")
    }

    @Test func roundTripsH264WhereThereIsAnEncoder() throws {
        do {
            try roundTrip(fileName: "pictures.mp4", codec: .h264)
        } catch VideoCodecError.unsupportedCodec {
            // No H.264 encoder here.
        }
    }

    @Test func writesAndReadsPCM() throws {
        let format = AudioFormat.linearPCM(sampleRate: 8000, channelLayout: .stereo, layout: .int16)
        let frames = 800
        let bytes = (0..<frames * 4).map { UInt8(truncatingIfNeeded: $0) }
        try withTemporaryFile(named: "tone.wav") { path in
            let writer = try MediaWriter(url: path)
            #expect(writer.container == "wav")
            let track = try writer.addTrack(.audio(format), timescale: 8000)
            try writer.write(SampleBuffer(
                data: BlockBuffer(bytes: bytes), format: .audio(format),
                timing: SampleTiming(presentationTime: .zero, duration: MediaTime(value: Int64(frames), timescale: 8000)),
                flags: .sync
            ), to: track)
            try writer.finish()

            let reader = try MediaReader(url: path)
            guard case .audio(let read)? = reader.tracks.first?.format else {
                Issue.record("the track is audio")
                return
            }
            #expect(read.codec == .linearPCM)
            #expect(read.pcm == .int16)
            #expect(read.sampleRate == 8000)
            #expect(read.channelCount == 2)
            let samples = try readAll(reader)
            #expect(samples.flatMap { $0.sample.data?.bytes ?? [] } == bytes)
        }
    }

    @Test func seeksToTheKeyframeBefore() throws {
        let (format, written) = try encoded(count: 15)
        try withTemporaryFile(named: "pictures.mkv") { path in
            let writer = try MediaWriter(url: path)
            let track = try writer.addTrack(.video(format), timescale: 30)
            for sample in written { try writer.write(sample, to: track) }
            try writer.finish()

            let reader = try MediaReader(url: path)
            // Keyframes are at 0, 5 and 10: 7 is after the second.
            try reader.seek(to: MediaTime(value: 7, timescale: 30))
            let first = try #require(try reader.nextSample())
            #expect(first.sample.isSync)
            #expect(milliseconds(first.sample.presentationTime) == 167)
        }
    }

    @Test func selectsTracks() throws {
        let (format, written) = try encoded(count: 4)
        try withTemporaryFile(named: "two.mkv") { path in
            let writer = try MediaWriter(url: path)
            let first = try writer.addTrack(.video(format), timescale: 30)
            let second = try writer.addTrack(.video(format), timescale: 30)
            for sample in written {
                try writer.write(sample, to: first)
                try writer.write(sample, to: second)
            }
            try writer.finish()

            let reader = try MediaReader(url: path)
            #expect(reader.tracks.map(\.id) == [first, second])
            try reader.select(tracks: [second])
            let samples = try readAll(reader)
            #expect(samples.count == written.count)
            #expect(samples.allSatisfy { $0.track == second })
            #expect(throws: MediaFilesError.noSuchTrack(9)) { try reader.select(tracks: [9]) }
        }
    }

    @Test func refusesWhatItCantDo() throws {
        #expect {
            try MediaReader(url: "/nonexistent/file.mp4")
        } throws: { error in
            if case MediaFilesError.cannotOpen = error { true } else { false }
        }
        #expect(throws: MediaFilesError.unknownContainer("file.zzzz")) {
            try MediaWriter(url: "file.zzzz")
        }
        let (format, written) = try encoded(count: 1)
        try withTemporaryFile(named: "one.mp4") { path in
            let writer = try MediaWriter(url: path)
            #expect {
                try writer.addTrack(.video(VideoFormat(codec: "zzzz", width: 16, height: 16)), timescale: 30)
            } throws: { error in
                if case MediaFilesError.unsupportedFormat = error { true } else { false }
            }
            let track = try writer.addTrack(.video(format), timescale: 30)
            #expect(throws: MediaFilesError.noSuchTrack(track + 5)) { try writer.write(written[0], to: track + 5) }
            try writer.write(written[0], to: track)
            #expect(throws: MediaFilesError.alreadyWriting) { try writer.addTrack(.video(format), timescale: 30) }
            try writer.finish()
            // Finishing twice is fine; writing after isn't.
            try writer.finish()
            #expect(throws: MediaFilesError.finished) { try writer.write(written[0], to: track) }
        }
    }
}
