import MediaCore
import PixelBuffers
import Synchronization
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@Suite struct PixelBufferTests {

    @Test func laysOutPlanesRoundingOddSizesUp() {
        let buffer = PixelBuffer(width: 5, height: 3, format: .nv12, rowAlignment: 16)
        #expect(buffer.planes.count == 2)
        #expect(buffer.planes[0] == PixelBuffer.Plane(width: 5, height: 3, bytesPerRow: 16))
        // Chroma: three pairs across, two rows down, two bytes a pair.
        #expect(buffer.planes[1] == PixelBuffer.Plane(width: 3, height: 2, bytesPerRow: 16))
        let i420 = PixelBuffer(width: 1920, height: 1080, format: .i420)
        #expect(i420.planes.map(\.width) == [1920, 960, 960])
        #expect(i420.planes.map(\.height) == [1080, 540, 540])
        #expect(i420.planes.allSatisfy { $0.bytesPerRow % 64 == 0 })
        #expect(PixelBuffer(width: 3, height: 2, format: .bgra8, rowAlignment: 4).planes[0].bytesPerRow == 12)
    }

    @Test func startsBlack() {
        let nv12 = PixelBuffer(width: 4, height: 4, format: .nv12)
        #expect(nv12.withPlane(0) { $0.allSatisfy { $0 == 0 } })
        #expect(nv12.withPlane(1) { $0.allSatisfy { $0 == 128 } })
        let p010 = PixelBuffer(width: 4, height: 4, format: .p010)
        // 512 in the high ten bits of 16, little-endian: 0x8000.
        #expect(p010.withPlane(1) { $0.load(as: UInt16.self) } == UInt16(0x8000).littleEndian)
        #expect(PixelBuffer(width: 2, height: 2, format: .bgra8).withPlane(0) { $0.allSatisfy { $0 == 0 } })
    }

    @Test func writesAndReadsPixels() {
        let buffer = PixelBuffer(width: 4, height: 2, format: .bgra8, color: .sRGB)
        buffer.withMutablePlane(0) { plane in
            plane[buffer.byteOffset(plane: 0, x: 3, y: 1) + 2] = 255
        }
        #expect(buffer.withPlane(0) { $0[buffer.planes[0].bytesPerRow + 3 * 4 + 2] } == 255)
        #expect(buffer.color == .sRGB)
        #expect(buffer.isInMemory)
        // It's a picture a sample buffer can carry.
        let sample = SampleBuffer(image: buffer, format: nil, timing: SampleTiming(presentationTime: .zero))
        #expect(sample.image?.width == 4)
    }

    @Test func wrapsAnotherLibrarysPlanes() {
        let released = Counter()
        let luma = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        let chroma = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        luma.initializeMemory(as: UInt8.self, repeating: 7, count: 32)
        let addresses = (UInt(bitPattern: luma), UInt(bitPattern: chroma))
        do {
            let buffer = PixelBuffer(width: 4, height: 4, format: .nv12, planesNoCopy: [(luma, 8), (chroma, 8)]) {
                released.increment()
                UnsafeMutableRawPointer(bitPattern: addresses.0)?.deallocate()
                UnsafeMutableRawPointer(bitPattern: addresses.1)?.deallocate()
            }
            withExtendedLifetime(buffer) {
                #expect(buffer.planes[1] == PixelBuffer.Plane(width: 2, height: 2, bytesPerRow: 8))
                #expect(buffer.withPlane(0) { $0.baseAddress } == UnsafeRawPointer(luma))
                #expect(buffer.withPlane(0) { $0[0] } == 7)
                #expect(released.value == 0)
            }
        }
        #expect(released.value == 1)
    }

    @Test func closesItsDMABufferOnce() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let (read, write) = (descriptors[0], descriptors[1])
        defer { close(write) }
        do {
            // Both planes in one descriptor, as decoders export NV12.
            let buffer = PixelBuffer(width: 64, height: 64, format: .nv12, dmaBuffer: DMABuffer(planes: [
                DMABuffer.Plane(fileDescriptor: read, offset: 0, bytesPerRow: 64),
                DMABuffer.Plane(fileDescriptor: read, offset: 4096, bytesPerRow: 64),
            ]))
            withExtendedLifetime(buffer) {
                #expect(!buffer.isInMemory)
                #expect(fcntl(read, F_GETFD) != -1)
            }
        }
        #expect(fcntl(read, F_GETFD) == -1)
    }
}

@Suite struct PixelBufferPoolTests {

    @Test func reusesTheMemoryOfBuffersThatWent() {
        let pool = PixelBufferPool(width: 64, height: 32, format: .nv12)
        var first: UnsafeRawPointer?
        do {
            let buffer = pool.makeBuffer(color: .bt709)
            withExtendedLifetime(buffer) {
                first = buffer.withPlane(0) { $0.baseAddress }
                #expect(buffer.color == .bt709)
                #expect(pool.idleCount == 0)
            }
        }
        #expect(pool.idleCount == 1)
        let again = pool.makeBuffer()
        #expect(again.withPlane(0) { $0.baseAddress } == first)
        #expect(pool.idleCount == 0)
        #expect(again.planes == PixelBuffer(width: 64, height: 32, format: .nv12).planes)
    }

    @Test func keepsNoMoreThanItsLimit() {
        let pool = PixelBufferPool(width: 8, height: 8, format: .bgra8, maximumIdleCount: 2)
        do {
            let buffers = (0..<5).map { _ in pool.makeBuffer() }
            #expect(buffers.count == 5)
        }
        #expect(pool.idleCount == 2)
        pool.flush()
        #expect(pool.idleCount == 0)
    }
}
