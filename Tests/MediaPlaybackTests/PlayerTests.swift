import AudioCodec
import Foundation
import MediaCore
import MediaFiles
import MediaPlayback
import PixelBuffers
import Testing
import VideoCodec

/// A clock the test moves.
final class ManualClock: HostClock {
    var now: MediaTime = .zero
}

/// An output that plays only when the test says, and keeps what it's given.
final class TestAudioOutput: AudioOutput {
    var format: AudioFormat?
    var enqueued: [SampleBuffer] = []
    var queued: MediaTime = .zero
    var isPaused = true
    var flushes = 0

    func open(_ format: AudioFormat) throws { self.format = format }

    func enqueue(_ pcm: SampleBuffer) throws {
        enqueued.append(pcm)
        queued = queued + pcm.duration
    }

    var queuedDuration: MediaTime { queued }

    func flush() {
        queued = .zero
        enqueued = []
        flushes += 1
    }

    /// Plays `duration` of what's queued, unless paused.
    func play(_ duration: MediaTime) {
        guard !isPaused else { return }
        queued = max(.zero, queued - duration)
    }
}

/// Plays a second of 30 pictures a second, a keyframe every five, and a
/// second of AAC, from a Matroska file.
@Suite struct PlayerTests {

    private static func seconds(_ milliseconds: Int64) -> MediaTime {
        MediaTime(value: milliseconds, timescale: 1000)
    }

    /// Whether two times are within two milliseconds: Matroska rounds to
    /// one.
    private func near(_ time: MediaTime?, _ milliseconds: Int64) -> Bool {
        guard let time else { return false }
        return abs(time.seconds - Double(milliseconds) / 1000) < 0.002
    }

    /// A picture's frame number, at 30 a second.
    private func frame(_ picture: SampleBuffer?) -> Int? {
        picture.map { Int(($0.presentationTime.seconds * 30).rounded()) }
    }

    /// Writes the file to a directory of its own, and plays it with `body`.
    private func withMovie<T>(audio: Bool = true, _ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("movie.mkv").path

        let video = try VideoEncoder(settings: VideoEncoder.Settings(
            codec: .mpeg4Video, width: 32, height: 32, timescale: 30, keyframeInterval: 5
        ))
        var pictures: [SampleBuffer] = []
        for index in 0..<30 {
            let picture = PixelBuffer(width: 32, height: 32, format: .i420)
            picture.withMutablePlane(0) { luma in
                for offset in luma.indices { luma[offset] = UInt8(truncatingIfNeeded: index * 8) }
            }
            pictures += try video.encode(picture, presentationTime: MediaTime(value: Int64(index), timescale: 30), keyframe: index % 5 == 0)
        }
        pictures += try video.finish()

        let writer = try MediaWriter(url: path)
        let videoTrack = try writer.addTrack(.video(video.format), timescale: 30)
        var sound: [SampleBuffer] = []
        var audioTrack = 0
        if audio {
            let encoder = try AudioEncoder(settings: AudioEncoder.Settings(codec: .aac, sampleRate: 48000, channelLayout: .stereo))
            let pcm = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .float32)
            for chunk in 0..<10 {
                var bytes: [UInt8] = []
                for frame in 0..<4800 {
                    let value = Float(0.3 * sin(Double(chunk * 4800 + frame) * 0.05))
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes += $0; bytes += $0 }
                }
                sound += try encoder.encode(SampleBuffer(
                    content: .data(BlockBuffer(bytes: bytes)), format: .audio(pcm),
                    timing: SampleTiming(presentationTime: MediaTime(value: Int64(chunk * 4800), timescale: 48000)),
                    sampleCount: 4800, flags: .sync
                ))
            }
            sound += try encoder.finish()
            // AAC's priming packet is timed before zero, which Matroska can't
            // keep: libavformat would move everything later to fit it.
            sound.removeAll { $0.presentationTime < .zero }
            audioTrack = try writer.addTrack(.audio(encoder.format), timescale: 48000)
        }
        for picture in pictures { try writer.write(picture, to: videoTrack) }
        for packet in sound { try writer.write(packet, to: audioTrack) }
        try writer.finish()
        return try body(path)
    }

    @Test func opensPausedAtTheFirstPicture() throws {
        try withMovie { path in
            let output = TestAudioOutput()
            let player = try Player(url: path, audioOutput: output, clock: ManualClock())
            #expect(player.videoTrack != nil)
            #expect(player.audioTrack != nil)
            #expect(output.format == .linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .float32))
            #expect(abs(player.duration.seconds - 1) < 0.1)
            #expect(frame(try player.update()) == 0)
            #expect(player.state == .paused)
            #expect(near(player.currentTime, 0))
            // Sound is queued ahead, from the start, and held.
            #expect(output.isPaused)
            #expect(output.queued >= player.options.audioAhead)
            #expect(near(output.enqueued.first?.presentationTime, 0))
        }
    }

    @Test func followsTheSound() throws {
        try withMovie { path in
            let output = TestAudioOutput()
            let player = try Player(url: path, audioOutput: output, clock: ManualClock())
            try player.update()
            player.play()
            #expect(!output.isPaused)
            output.play(Self.seconds(200))
            #expect(frame(try player.update()) == 6)
            #expect(near(player.currentTime, 200))
            // Still queued ahead.
            #expect(output.queued >= player.options.audioAhead)

            player.pause()
            #expect(output.isPaused)
            output.play(Self.seconds(300))
            #expect(frame(try player.update()) == 6)
            #expect(near(player.currentTime, 200))
        }
    }

    @Test func seeks() throws {
        try withMovie { path in
            let output = TestAudioOutput()
            let player = try Player(url: path, audioOutput: output, clock: ManualClock())
            try player.update()
            // Frame 15 is a keyframe; 22 decodes from 20.
            for (time, expected) in [(500, 15), (740, 22), (100, 3)] {
                player.seek(to: Self.seconds(Int64(time)))
                #expect(frame(try player.update()) == expected)
                #expect(near(player.currentTime, Int64(time)))
                // Sound starts there, not at the packet before.
                #expect(near(output.enqueued.first?.presentationTime, Int64(time)))
            }
            #expect(output.flushes == 3)
        }
    }

    @Test func playsToTheEnd() throws {
        try withMovie { path in
            let output = TestAudioOutput()
            let player = try Player(url: path, audioOutput: output, clock: ManualClock())
            player.play()
            var shown: [Int] = []
            for _ in 0..<100 where player.state == .playing {
                if let number = frame(try player.update()), shown.last != number { shown.append(number) }
                output.play(Self.seconds(20))
            }
            #expect(player.state == .ended)
            #expect(shown.first == 0)
            #expect(shown.last == 29)
            #expect(shown == shown.sorted())
            // Playing again starts over.
            player.play()
            #expect(frame(try player.update()) == 0)
        }
    }

    @Test func followsTheHostClockWithoutSound() throws {
        try withMovie(audio: false) { path in
            let clock = ManualClock()
            let player = try Player(url: path, clock: clock)
            #expect(player.audioTrack == nil)
            #expect(frame(try player.update()) == 0)
            player.play()
            clock.now = Self.seconds(400)
            #expect(frame(try player.update()) == 12)
            player.pause()
            clock.now = Self.seconds(900)
            #expect(frame(try player.update()) == 12)
            player.play()
            clock.now = Self.seconds(2000)
            #expect(frame(try player.update()) == 29)
            #expect(player.state == .ended)
        }
    }

    @Test func playsNoSoundWithoutAnOutput() throws {
        try withMovie { path in
            let player = try Player(url: path, clock: ManualClock())
            #expect(player.videoTrack != nil)
            #expect(player.audioTrack == nil)
            #expect(frame(try player.update()) == 0)
        }
    }

    @Test func refusesWhatItCantOpen() {
        #expect(throws: (any Error).self) {
            try Player(url: "/nonexistent/movie.mkv")
        }
    }
}
