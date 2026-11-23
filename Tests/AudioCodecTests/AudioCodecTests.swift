import AudioCodec
import Foundation
import MediaCore
import Testing

/// Encodes PCM and decodes it again, with libavcodec's own codecs.
@Suite struct AudioCodecTests {

    /// `frames` frames of a 440 Hz sine, in every channel, as 16-bit
    /// integers or 32-bit floats, interleaved.
    private func sine(frames: Int, rate: Double, channels: Int, layout: PCMLayout) -> [UInt8] {
        var bytes: [UInt8] = []
        for frame in 0..<frames {
            let value = 0.5 * sin(2 * Double.pi * 440 * Double(frame) / rate)
            for _ in 0..<channels {
                if layout == .int16 {
                    withUnsafeBytes(of: Int16(value * 32767).littleEndian) { bytes += $0 }
                } else {
                    withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { bytes += $0 }
                }
            }
        }
        return bytes
    }

    /// PCM cut into buffers of `chunk` frames, timed from zero.
    private func buffers(_ bytes: [UInt8], format: AudioFormat, chunk: Int) -> [SampleBuffer] {
        let bytesPerFrame = format.bytesPerFrame!
        let rate = Int32(format.sampleRate)
        return stride(from: 0, to: bytes.count, by: chunk * bytesPerFrame).map { offset in
            let end = min(offset + chunk * bytesPerFrame, bytes.count)
            let frames = (end - offset) / bytesPerFrame
            return SampleBuffer(
                content: .data(BlockBuffer(bytes: bytes[offset..<end])),
                format: .audio(format),
                timing: SampleTiming(
                    presentationTime: MediaTime(value: Int64(offset / bytesPerFrame), timescale: rate),
                    duration: MediaTime(value: Int64(frames), timescale: rate)
                ),
                sampleCount: frames,
                flags: .sync
            )
        }
    }

    /// Encodes PCM and decodes the packets: the packets and the PCM.
    private func roundTrip(
        _ settings: AudioEncoder.Settings, input: [SampleBuffer], options: AudioDecoder.Options = AudioDecoder.Options()
    ) throws -> (encoder: AudioEncoder, packets: [SampleBuffer], decoded: [SampleBuffer]) {
        let encoder = try AudioEncoder(settings: settings)
        var packets: [SampleBuffer] = []
        for buffer in input { packets += try encoder.encode(buffer) }
        packets += try encoder.finish()
        let decoder = try AudioDecoder(format: encoder.format, options: options)
        var decoded: [SampleBuffer] = []
        for packet in packets { decoded += try decoder.decode(packet) }
        decoded += try decoder.finish()
        return (encoder, packets, decoded)
    }

    /// Floats from interleaved 32-bit PCM.
    private func floats(_ buffers: [SampleBuffer]) -> [Float] {
        let bytes = buffers.flatMap { $0.data?.bytes ?? [] }
        return stride(from: 0, to: bytes.count - 3, by: 4).map { index in
            Float(bitPattern: UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24)
        }
    }

    private func rms(_ values: ArraySlice<Float>) -> Double {
        (values.reduce(0) { $0 + Double($1 * $1) } / Double(max(values.count, 1))).squareRoot()
    }

    @Test func flacIsLossless() throws {
        let format = AudioFormat.linearPCM(sampleRate: 44100, channelLayout: .stereo, layout: .int16)
        let bytes = sine(frames: 10_000, rate: 44100, channels: 2, layout: .int16)
        let (encoder, packets, decoded) = try roundTrip(
            AudioEncoder.Settings(codec: .flac, sampleRate: 44100, channelLayout: .stereo),
            input: buffers(bytes, format: format, chunk: 1000),
            options: AudioDecoder.Options(layout: .int16)
        )
        #expect(!encoder.format.magicCookie.isEmpty)
        #expect(!packets.isEmpty)
        #expect(decoded.flatMap { $0.data?.bytes ?? [] } == bytes)
        #expect(decoded.reduce(0) { $0 + $1.sampleCount } == 10_000)
        #expect(decoded.first?.presentationTime == .zero)
        if case .audio(let pcm)? = decoded.first?.format {
            #expect(pcm == .linearPCM(sampleRate: 44100, channelLayout: .stereo, layout: .int16))
        } else {
            Issue.record("decoded audio is audio")
        }
        // Each buffer starts where the last ended.
        for (previous, next) in zip(decoded, decoded.dropFirst()) {
            #expect(previous.presentationTime + previous.duration == next.presentationTime)
        }
    }

    @Test func roundTripsAAC() throws {
        let format = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .float32)
        let bytes = sine(frames: 24_000, rate: 48000, channels: 2, layout: .float32)
        let (encoder, packets, decoded) = try roundTrip(
            AudioEncoder.Settings(codec: .aac, sampleRate: 48000, channelLayout: .stereo, bitRate: 128_000),
            input: buffers(bytes, format: format, chunk: 700)
        )
        #expect(!encoder.format.magicCookie.isEmpty)
        #expect(encoder.format.framesPerPacket == 1024)
        #expect(packets.allSatisfy { $0.isSync })
        let frames = decoded.reduce(0) { $0 + $1.sampleCount }
        // AAC adds priming and pads its last frame.
        #expect(frames >= 24_000 && frames <= 24_000 + 3 * 1024)
        let source = floats(buffers(bytes, format: format, chunk: 24_000))
        let output = floats(decoded)
        let middle = rms(output[output.count / 4..<output.count / 2])
        #expect(abs(middle - rms(source[...])) < 0.05)
    }

    @Test func roundTripsOpusWhereThereIsAnEncoder() throws {
        let format = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .float32)
        let bytes = sine(frames: 9600, rate: 48000, channels: 2, layout: .float32)
        do {
            let (_, packets, decoded) = try roundTrip(
                AudioEncoder.Settings(codec: .opus, sampleRate: 48000, channelLayout: .stereo, bitRate: 96_000),
                input: buffers(bytes, format: format, chunk: 480)
            )
            #expect(!packets.isEmpty)
            #expect(decoded.reduce(0) { $0 + $1.sampleCount } >= 9600)
        } catch AudioCodecError.unsupportedCodec {
            // No Opus encoder here.
        }
    }

    @Test func convertsRateChannelsAndLayout() throws {
        let format = AudioFormat.linearPCM(sampleRate: 44100, channelLayout: .stereo, layout: .int16)
        let bytes = sine(frames: 44_100, rate: 44100, channels: 2, layout: .int16)
        let planar = PCMLayout(sampleType: .float, bitsPerSample: 32, isInterleaved: false)
        let (_, _, decoded) = try roundTrip(
            AudioEncoder.Settings(codec: .flac, sampleRate: 44100, channelLayout: .stereo),
            input: buffers(bytes, format: format, chunk: 4410),
            options: AudioDecoder.Options(layout: planar, sampleRate: 24000, channelLayout: .mono)
        )
        let frames = decoded.reduce(0) { $0 + $1.sampleCount }
        #expect(abs(frames - 24000) <= 64)
        for buffer in decoded {
            #expect(buffer.data?.count == buffer.sampleCount * 4)
            if case .audio(let pcm)? = buffer.format {
                #expect(pcm.sampleRate == 24000 && pcm.channelCount == 1 && pcm.pcm == planar)
            }
        }
    }

    @Test func encodesFromAnotherRate() throws {
        // 44.1 kHz in, 48 kHz AAC out.
        let format = AudioFormat.linearPCM(sampleRate: 44100, channelLayout: .mono, layout: .int16)
        let bytes = sine(frames: 22_050, rate: 44100, channels: 1, layout: .int16)
        let (encoder, _, decoded) = try roundTrip(
            AudioEncoder.Settings(codec: .aac, sampleRate: 48000, channelLayout: .mono),
            input: buffers(bytes, format: format, chunk: 1000)
        )
        #expect(encoder.format.sampleRate == 48000)
        let frames = decoded.reduce(0) { $0 + $1.sampleCount }
        #expect(frames >= 24_000 - 64 && frames <= 24_000 + 3 * 1024)
    }

    @Test func refusesWhatItCantDo() throws {
        #expect(throws: AudioCodecError.unsupportedCodec("zzzz")) {
            try AudioDecoder(format: AudioFormat(codec: "zzzz", sampleRate: 48000, channelLayout: .stereo))
        }
        let format = AudioFormat(codec: .aac, sampleRate: 48000, channelLayout: .stereo)
        #expect(throws: AudioCodecError.unsupportedLayout("24-bit signed")) {
            try AudioDecoder(format: format, options: AudioDecoder.Options(layout: PCMLayout(sampleType: .signedInteger, bitsPerSample: 24)))
        }
        let decoder = try AudioDecoder(format: format)
        #expect(throws: AudioCodecError.noData) {
            try decoder.decode(SampleBuffer(content: .empty, format: nil, timing: SampleTiming(presentationTime: .zero)))
        }
        #expect(try decoder.finish().isEmpty)
        let encoder = try AudioEncoder(settings: AudioEncoder.Settings(codec: .aac, sampleRate: 48000, channelLayout: .stereo))
        let pcm = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .stereo, layout: .int16)
        #expect(throws: AudioCodecError.mismatchedAudio) {
            // Three bytes isn't a frame of 16-bit stereo.
            try encoder.encode(SampleBuffer(data: BlockBuffer(bytes: [1, 2, 3]), format: .audio(pcm), timing: SampleTiming(presentationTime: .zero)))
        }
        #expect(throws: AudioCodecError.mismatchedAudio) {
            try encoder.encode(SampleBuffer(data: BlockBuffer(bytes: [1, 2, 3, 4]), format: .audio(format), timing: SampleTiming(presentationTime: .zero)))
        }
        // Finishing before anything, and twice, gives nothing.
        #expect(try encoder.finish().isEmpty)
        #expect(try encoder.finish().isEmpty)
    }
}
