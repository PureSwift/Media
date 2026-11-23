import Foundation
import MediaCore
import MediaFiles
import MediaPlayback
import MediaSDL
import Testing

/// Plays through SDL's dummy driver, which takes sound as fast as a device
/// would, and plays it nowhere.
@Suite(.serialized) struct SDLAudioOutputTests {

    init() {
        setenv("SDL_AUDIO_DRIVER", "dummy", 1)
    }

    private let format = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .float32)

    /// `seconds` of silence in the format.
    private func silence(_ seconds: Double) -> SampleBuffer {
        let frames = Int(seconds * 48000)
        return SampleBuffer(
            content: .data(BlockBuffer(bytes: [UInt8](repeating: 0, count: frames * 8))),
            format: .audio(format),
            timing: SampleTiming(presentationTime: .zero, duration: MediaTime(value: Int64(frames), timescale: 48000)),
            sampleCount: frames, flags: .sync
        )
    }

    @Test func holdsWhatsQueuedWhilePaused() throws {
        let output = try SDLAudioOutput()
        try output.open(format)
        #expect(output.isPaused)
        try output.enqueue(silence(0.5))
        #expect(output.queuedDuration == MediaTime(value: 24000, timescale: 48000))
        Thread.sleep(forTimeInterval: 0.15)
        #expect(output.queuedDuration == MediaTime(value: 24000, timescale: 48000))
        output.flush()
        #expect(output.queuedDuration == .zero)
    }

    @Test func playsWhenResumed() throws {
        let output = try SDLAudioOutput()
        try output.open(format)
        try output.enqueue(silence(1))
        output.isPaused = false
        // The device may start late on a busy machine.
        var waited = 0.0
        while output.queuedDuration.seconds > 0.9, waited < 3 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 0.05
        }
        let left = output.queuedDuration.seconds
        #expect(left <= 0.9)
        #expect(left > 0.2)
        output.isPaused = true
        Thread.sleep(forTimeInterval: 0.1)
        let held = output.queuedDuration.seconds
        Thread.sleep(forTimeInterval: 0.15)
        #expect(output.queuedDuration.seconds == held)
    }

    @Test func refusesWhatSDLCantPlay() throws {
        let output = try SDLAudioOutput()
        #expect(throws: SDLAudioOutput.Error.notOpen) { try output.enqueue(silence(0.1)) }
        let planar = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo,
                                           layout: PCMLayout(sampleType: .float, bitsPerSample: 32, isInterleaved: false))
        #expect(throws: SDLAudioOutput.Error.self) { try output.open(planar) }
        let deep = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: PCMLayout(sampleType: .float, bitsPerSample: 64))
        #expect(throws: SDLAudioOutput.Error.self) { try output.open(deep) }
    }

    @Test func playsAPlayersSound() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SDLAudioOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tone.wav").path
        let pcm = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .int16)
        let writer = try MediaWriter(url: path)
        let track = try writer.addTrack(.audio(pcm), timescale: 48000)
        for chunk in 0..<10 {
            try writer.write(SampleBuffer(
                content: .data(BlockBuffer(bytes: [UInt8](repeating: 0, count: 4800 * 4))), format: .audio(pcm),
                timing: SampleTiming(presentationTime: MediaTime(value: Int64(chunk * 4800), timescale: 48000),
                                     duration: MediaTime(value: 4800, timescale: 48000)),
                sampleCount: 4800, flags: .sync
            ), to: track)
        }
        try writer.finish()

        let output = try SDLAudioOutput()
        let player = try Player(url: path, audioOutput: output)
        #expect(player.audioTrack != nil)
        try player.update()
        #expect(player.currentTime.seconds < 0.01)
        player.play()
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.02)
            try player.update()
        }
        // About 0.4 s played, by the sound.
        #expect(player.currentTime.seconds > 0.2)
        #expect(player.currentTime.seconds < 0.6)
        #expect(output.queuedDuration >= MediaTime(value: 1, timescale: 4))
    }
}
