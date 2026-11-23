import MediaCore
import PixelBuffers
import Testing
import VideoCodec

/// Converts YUV pictures to RGB, and scales them, with libswscale.
@Suite struct PixelConverterTests {

    /// An I420 or NV12 picture of one color, as Y, Cb and Cr.
    private func solid(_ format: PixelFormat, y: UInt8, cb: UInt8, cr: UInt8, color: ColorInfo = .bt709,
                       width: Int = 64, height: Int = 48) -> PixelBuffer {
        let picture = PixelBuffer(width: width, height: height, format: format, color: color)
        picture.withMutablePlane(0) { luma in luma.initializeMemory(as: UInt8.self, repeating: y) }
        if format == .nv12 {
            picture.withMutablePlane(1) { chroma in
                for index in stride(from: 0, to: chroma.count - 1, by: 2) {
                    chroma[index] = cb
                    chroma[index + 1] = cr
                }
            }
        } else {
            picture.withMutablePlane(1) { $0.initializeMemory(as: UInt8.self, repeating: cb) }
            picture.withMutablePlane(2) { $0.initializeMemory(as: UInt8.self, repeating: cr) }
        }
        return picture
    }

    /// The four bytes of a picture's pixel.
    private func pixel(_ picture: PixelBuffer, x: Int = 10, y: Int = 10) -> [Int] {
        picture.withPlane(0) { plane in
            let offset = y * picture.planes[0].bytesPerRow + x * 4
            return (0..<4).map { Int(plane[offset + $0]) }
        }
    }

    private func near(_ a: [Int], _ b: [Int], within tolerance: Int = 3) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func convertsVideoRangeYUVToBGRA() throws {
        let converter = try PixelConverter(to: .bgra8)
        let white = try converter.convert(solid(.i420, y: 235, cb: 128, cr: 128))
        #expect(white.format == .bgra8)
        #expect(white.width == 64 && white.height == 48)
        #expect(near(pixel(white), [255, 255, 255, 255]))
        #expect(near(pixel(try converter.convert(solid(.i420, y: 16, cb: 128, cr: 128))), [0, 0, 0, 255]))
        // BT.709 red, in B, G, R, A.
        let red = try converter.convert(solid(.i420, y: 63, cb: 102, cr: 240))
        #expect(near(pixel(red), [0, 0, 255, 255]))
        #expect(red.color.matrix == .identity)
        #expect(red.color.range == .full)
        #expect(red.color.primaries == .bt709)
    }

    @Test func convertsNV12ToRGBA() throws {
        let converter = try PixelConverter(to: .rgba8)
        let red = try converter.convert(solid(.nv12, y: 63, cb: 102, cr: 240))
        #expect(near(pixel(red), [255, 0, 0, 255]))
    }

    @Test func followsThePicturesRangeAndMatrix() throws {
        let converter = try PixelConverter(to: .bgra8)
        let full = ColorInfo(primaries: .bt709, transferFunction: .bt709, matrix: .bt709, range: .full)
        #expect(near(pixel(try converter.convert(solid(.i420, y: 255, cb: 128, cr: 128, color: full))), [255, 255, 255, 255]))
        #expect(near(pixel(try converter.convert(solid(.i420, y: 235, cb: 128, cr: 128, color: full))), [235, 235, 235, 255]))
        // BT.601 red differs from BT.709's.
        let standard = ColorInfo(primaries: .smpte170M, transferFunction: .smpte170M, matrix: .smpte170M, range: .video)
        #expect(near(pixel(try converter.convert(solid(.i420, y: 81, cb: 90, cr: 240, color: standard))), [0, 0, 255, 255]))
    }

    @Test func scales() throws {
        let converter = try PixelConverter(to: .bgra8, width: 32, height: 24)
        let small = try converter.convert(solid(.i420, y: 235, cb: 128, cr: 128))
        #expect(small.width == 32 && small.height == 24)
        #expect(near(pixel(small, x: 31, y: 23), [255, 255, 255, 255]))
        // Into a buffer of any size.
        let large = PixelBuffer(width: 128, height: 96, format: .bgra8)
        try converter.convert(solid(.i420, y: 16, cb: 128, cr: 128), into: large)
        #expect(near(pixel(large, x: 127, y: 95), [0, 0, 0, 255]))
    }

    @Test func refusesWhatItCantConvert() throws {
        let converter = try PixelConverter(to: .bgra8)
        #expect(throws: VideoCodecError.mismatchedPicture) {
            try converter.convert(solid(.i420, y: 16, cb: 128, cr: 128), into: PixelBuffer(width: 8, height: 8, format: .rgba8))
        }
    }
}
