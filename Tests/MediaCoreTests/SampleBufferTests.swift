import MediaCore
import Synchronization
import Testing

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@Suite struct BlockBufferTests {

    @Test func slicesShareTheirMemory() {
        let buffer = BlockBuffer(bytes: [1, 2, 3, 4, 5])
        let slice = buffer[1..<4]
        #expect(slice.bytes == [2, 3, 4])
        #expect(slice[1..<2].bytes == [3])
        buffer.withUnsafeBytes { whole in
            slice.withUnsafeBytes { part in
                #expect(part.baseAddress == whole.baseAddress! + 1)
            }
        }
    }

    @Test func releasesWrappedMemoryOnceWhenTheLastBufferGoes() {
        let released = Counter()
        let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 4, alignment: 1)
        memory.copyBytes(from: [9, 8, 7, 6])
        let address = UInt(bitPattern: memory.baseAddress)
        do {
            let buffer = BlockBuffer(bytesNoCopy: UnsafeRawBufferPointer(memory)) {
                released.increment()
                UnsafeMutableRawPointer(bitPattern: address)?.deallocate()
            }
            let slice = buffer[2..<4]
            withExtendedLifetime(slice) {
                #expect(slice.bytes == [7, 6])
                #expect(released.value == 0)
            }
        }
        #expect(released.value == 1)
    }

    @Test func concatenatesAndCompares() {
        let joined = BlockBuffer(concatenating: [BlockBuffer(bytes: [1, 2]), BlockBuffer(bytes: [3])])
        #expect(joined == BlockBuffer(bytes: [1, 2, 3]))
        #expect(joined != BlockBuffer(bytes: [1, 2, 4]))
        #expect(BlockBuffer().isEmpty)
        let made = BlockBuffer(count: 3) { $0.copyBytes(from: [5, 5, 5]) }
        #expect(made.bytes == [5, 5, 5])
    }
}

@Suite struct SampleBufferTests {

    private let aac = FormatDescription.audio(AudioFormat(codec: .aac, sampleRate: 48000, channelLayout: .stereo, framesPerPacket: 1024))

    @Test func splitsIntoItsSamples() {
        let packets = SampleBuffer(
            content: .data(BlockBuffer(bytes: [1, 2, 3, 4, 5, 6])),
            format: aac,
            timing: SampleTiming(presentationTime: .zero, duration: MediaTime(value: 3072, timescale: 48000)),
            sampleCount: 3,
            sampleSizes: [1, 2, 3]
        )
        #expect(packets.samples.map(\.bytes) == [[1], [2, 3], [4, 5, 6]])
        let even = SampleBuffer(content: .data(BlockBuffer(bytes: [1, 2, 3, 4])), format: aac, timing: SampleTiming(presentationTime: .zero), sampleCount: 2)
        #expect(even.samples.map(\.bytes) == [[1, 2], [3, 4]])
    }

    @Test func knowsWhenItShows() {
        let frame = SampleBuffer(
            data: BlockBuffer(bytes: [0]),
            format: .video(VideoFormat(codec: .h264, width: 1920, height: 1080)),
            timing: SampleTiming(presentationTime: MediaTime(value: 2, timescale: 30), decodeTime: MediaTime(value: 1, timescale: 30),
                                 duration: MediaTime(value: 1, timescale: 30)),
            flags: .sync
        )
        #expect(frame.isSync)
        #expect(frame.presentationTimeRange == MediaTimeRange(start: MediaTime(value: 2, timescale: 30), end: MediaTime(value: 3, timescale: 30)))
        #expect(frame.timing.effectiveDecodeTime == MediaTime(value: 1, timescale: 30))
        #expect(frame.format?.mediaType == .video)
        #expect(frame.image == nil)
        let marker = SampleBuffer(content: .empty, format: nil, timing: SampleTiming(presentationTime: .zero))
        #expect(marker.samples.isEmpty)
        #expect(!marker.presentationTimeRange.isValid)
    }
}

@Suite struct FormatTests {

    @Test func fourCharacterCodesRoundTrip() {
        #expect(FourCharacterCode("avc1").rawValue == 0x6176_6331)
        #expect(FourCharacterCode("R8").description == "R8  ")
        #expect(CodecType.h264.description == "avc1")
        #expect(FourCharacterCode(rawValue: 0x0001_6162).description == "??ab")
    }

    @Test func videoShowsAtItsAspectRatio() {
        let dvd = VideoFormat(codec: .mpeg4Video, width: 720, height: 480, pixelAspectRatio: (32, 27))
        #expect(dvd.displaySize.width == 853)
        #expect(dvd.displaySize.height == 480)
        #expect(VideoFormat(codec: .h264, width: 1920, height: 1080).displaySize.width == 1920)
    }

    @Test func audioKnowsItsChannelsAndFrames() {
        let pcm = AudioFormat.linearPCM(sampleRate: 48000, channelLayout: .surround5_1, layout: .float32)
        #expect(pcm.channelCount == 6)
        #expect(pcm.bytesPerFrame == 24)
        #expect(AudioFormat(codec: .aac, sampleRate: 44100, channelLayout: .stereo).bytesPerFrame == nil)
        #expect(ChannelLayout.standard(channelCount: 2) == .stereo)
        #expect(ChannelLayout.standard(channelCount: 10).channels.count == 10)
    }
}
