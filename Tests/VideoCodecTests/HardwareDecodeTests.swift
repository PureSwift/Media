import Foundation
import MediaCore
import PixelBuffers
import Testing
import VideoCodec

/// Decodes H.264 on VA-API, where there's a device for it, into memory and
/// as dma-bufs. With `MEDIA_TEST_VAAPI=1` the hardware must be there;
/// without it, a machine without VA-API passes.
@Suite struct HardwareDecodeTests {

    private var requiresHardware: Bool {
        ProcessInfo.processInfo.environment["MEDIA_TEST_VAAPI"] == "1"
    }

    /// Ten pictures of a moving gradient, coded as H.264; nil without an
    /// encoder.
    private func encoded(width: Int = 128, height: Int = 96) throws -> (format: VideoFormat, samples: [SampleBuffer], pictures: [PixelBuffer])? {
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(settings: VideoEncoder.Settings(
                codec: .h264, width: width, height: height, timescale: 30, bitRate: 4_000_000, keyframeInterval: 5
            ))
        } catch VideoCodecError.unsupportedCodec {
            return nil
        }
        var samples: [SampleBuffer] = []
        var pictures: [PixelBuffer] = []
        for index in 0..<10 {
            let picture = PixelBuffer(width: width, height: height, format: .i420, color: .bt709)
            picture.withMutablePlane(0) { luma in
                for y in 0..<height {
                    for x in 0..<width {
                        luma[y * picture.planes[0].bytesPerRow + x] = UInt8(truncatingIfNeeded: 16 + (x + y * 2 + index * 6) % 200)
                    }
                }
            }
            pictures.append(picture)
            samples += try encoder.encode(picture, presentationTime: MediaTime(value: Int64(index), timescale: 30), keyframe: index == 0)
        }
        samples += try encoder.finish()
        return (encoder.format, samples, pictures)
    }

    private func decode(_ samples: [SampleBuffer], with decoder: VideoDecoder) throws -> [SampleBuffer] {
        var decoded: [SampleBuffer] = []
        for sample in samples { decoded += try decoder.decode(sample) }
        return decoded + (try decoder.finish())
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

    @Test func decodesOnVAAPIIntoMemory() throws {
        guard let (format, samples, sources) = try encoded() else { return }
        let decoder = try VideoDecoder(format: format, options: VideoDecoder.Options(hardware: .vaapi()))
        let decoded = try decode(samples, with: decoder)
        guard decoder.isHardwareAccelerated else {
            if requiresHardware { Issue.record("VA-API didn't decode") }
            return
        }
        #expect(decoded.count == 10)
        for (source, sample) in zip(sources, decoded) {
            let picture = try #require(sample.image as? PixelBuffer)
            #expect(picture.isInMemory)
            #expect(picture.format == .nv12)
            #expect(picture.width == 128 && picture.height == 96)
            #expect(lumaDifference(source, picture) < 6)
        }
        #expect(decoded.map(\.presentationTime) == (0..<10).map { MediaTime(value: Int64($0), timescale: 30) })
    }

    @Test func exportsDMABuffers() throws {
        guard let (format, samples, _) = try encoded() else { return }
        let decoder = try VideoDecoder(format: format, options: VideoDecoder.Options(hardware: .vaapi(), exportsDMABuffers: true))
        var count = 0
        var kept: [PixelBuffer] = []
        for batch in try samples.map({ try decoder.decode($0) }) + [decoder.finish()] {
            for picture in batch {
                let pixels = try #require(picture.image as? PixelBuffer)
                guard decoder.isHardwareAccelerated else { continue }
                count += 1
                #expect(!pixels.isInMemory)
                #expect(pixels.format == .nv12)
                #expect(pixels.width == 128 && pixels.height == 96)
                guard case .dmaBuffer(let buffer) = pixels.backing else {
                    Issue.record("a hardware picture is in dma-bufs")
                    continue
                }
                #expect(buffer.planes.count == 2)
                for plane in buffer.planes {
                    #expect(fcntl(plane.fileDescriptor, F_GETFD) >= 0)
                    #expect(plane.bytesPerRow >= 128)
                }
                // A viewer holds a few.
                kept.append(pixels)
                if kept.count > 3 { kept.removeFirst() }
            }
        }
        if count == 0, requiresHardware { Issue.record("VA-API didn't decode") }
        guard count > 0 else { return }
        #expect(count == 10)
        // Its descriptors are closed when it goes.
        guard case .dmaBuffer(let buffer)? = kept.last?.backing else { return }
        let descriptor = buffer.planes[0].fileDescriptor
        kept.removeAll()
        #expect(fcntl(descriptor, F_GETFD) == -1)
    }

    @Test func fallsBackToSoftware() throws {
        guard let (format, samples, _) = try encoded() else { return }
        let decoder = try VideoDecoder(format: format, options: VideoDecoder.Options(hardware: .vaapi(device: "/nonexistent")))
        let decoded = try decode(samples, with: decoder)
        #expect(!decoder.isHardwareAccelerated)
        #expect(decoded.count == 10)
        let picture = try #require(decoded.first?.image as? PixelBuffer)
        #expect(picture.isInMemory)
        #expect(picture.format == .i420)
    }
}
