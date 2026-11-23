import MediaCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// A picture's pixels: in memory, or in a GPU buffer shared as a dma-buf.
///
/// Its size, format and color are fixed when it's made. Pixels in memory
/// are read and written a plane at a time, through `withPlane` and
/// `withMutablePlane`; like a CoreVideo buffer's, they aren't guarded, so
/// whoever writes them makes sure nobody reads at the same time. A pixel
/// buffer from a pool goes back to the pool when the last reference to it
/// goes.
public final class PixelBuffer: MediaImage, @unchecked Sendable {

    /// Where a plane's rows are.
    public struct Plane: Hashable, Sendable {

        /// The plane's size in elements: pixels, or chroma samples or pairs.
        public var width: Int

        public var height: Int

        /// From one row's start to the next's, at least `width` elements'
        /// bytes.
        public var bytesPerRow: Int

        public init(width: Int, height: Int, bytesPerRow: Int) {
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
        }

        /// The bytes the plane spans.
        public var byteCount: Int { bytesPerRow * height }
    }

    public let width: Int

    public let height: Int

    public let format: PixelFormat

    public let color: ColorInfo

    /// Each plane of the format's, in order.
    public let planes: [Plane]

    /// What holds the pixels.
    public enum Backing: Sendable {
        /// Memory, which `withPlane` reads.
        case memory
        /// A shared GPU buffer, which a compositor or an encoder imports;
        /// its pixels aren't in this process's memory.
        case dmaBuffer(DMABuffer)
    }

    public let backing: Backing

    let storage: PixelStorage?

    /// The pool it goes back to.
    let pool: PixelBufferPool?

    /// For a shared GPU buffer, what lets go of what else keeps it.
    private let release: (@Sendable () -> Void)?

    // MARK: Making

    /// A buffer of black pixels in memory: each row aligned to
    /// `rowAlignment` bytes (a power of two), each plane starting aligned too.
    public convenience init(width: Int, height: Int, format: PixelFormat, color: ColorInfo = ColorInfo(), rowAlignment: Int = 64) {
        let layout = PixelBuffer.layout(width: width, height: height, format: format, rowAlignment: rowAlignment)
        let storage = PixelStorage(byteCount: layout.byteCount, offsets: layout.offsets, alignment: rowAlignment)
        storage.clear(format: format, planes: layout.planes)
        self.init(width: width, height: height, format: format, color: color, planes: layout.planes, storage: storage, pool: nil)
    }

    /// Pixels in memory another library owns, without copying them: a
    /// pointer and a row stride for each plane of the format's. The memory
    /// stays as it is until `release` is called, once, when the buffer goes.
    public convenience init(
        width: Int,
        height: Int,
        format: PixelFormat,
        color: ColorInfo = ColorInfo(),
        planesNoCopy planes: [(base: UnsafeMutableRawPointer, bytesPerRow: Int)],
        release: @escaping @Sendable () -> Void
    ) {
        precondition(planes.count == format.planes.count, "\(format) has \(format.planes.count) planes, not \(planes.count)")
        let described = zip(format.planes, planes).map { plane, given in
            let size = plane.size(width: width, height: height)
            return Plane(width: size.width, height: size.height, bytesPerRow: given.bytesPerRow)
        }
        let storage = PixelStorage(bases: planes.map(\.base), release: release)
        self.init(width: width, height: height, format: format, color: color, planes: described, storage: storage, pool: nil)
    }

    /// A shared GPU buffer's pixels, which this buffer now owns: its file
    /// descriptors are closed when it goes, and then `release` is called,
    /// for what else keeps the buffer, such as a decoder's frame.
    public init(
        width: Int,
        height: Int,
        format: PixelFormat,
        color: ColorInfo = ColorInfo(),
        dmaBuffer: DMABuffer,
        release: (@Sendable () -> Void)? = nil
    ) {
        precondition(dmaBuffer.planes.count == format.planes.count, "\(format) has \(format.planes.count) planes")
        self.width = width
        self.height = height
        self.format = format
        self.color = color
        self.planes = zip(format.planes, dmaBuffer.planes).map { plane, given in
            let size = plane.size(width: width, height: height)
            return Plane(width: size.width, height: size.height, bytesPerRow: given.bytesPerRow)
        }
        self.backing = .dmaBuffer(dmaBuffer)
        self.storage = nil
        self.pool = nil
        self.release = release
    }

    init(width: Int, height: Int, format: PixelFormat, color: ColorInfo, planes: [Plane], storage: PixelStorage, pool: PixelBufferPool?) {
        self.width = width
        self.height = height
        self.format = format
        self.color = color
        self.planes = planes
        self.backing = .memory
        self.storage = storage
        self.pool = pool
        self.release = nil
    }

    deinit {
        if case .dmaBuffer(let buffer) = backing {
            buffer.closeFileDescriptors()
            release?()
        } else if let pool, let storage {
            pool.recycle(storage)
        }
    }

    // MARK: Pixels

    /// Whether its pixels are in memory, for `withPlane`.
    public var isInMemory: Bool {
        if case .memory = backing { return true }
        return false
    }

    /// Reads plane `index`'s bytes, all its rows with their padding, which
    /// stay valid during the call only.
    public func withPlane<Result>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try withMutablePlane(index) { try body(UnsafeRawBufferPointer($0)) }
    }

    /// Writes plane `index`'s bytes, all its rows with their padding, which
    /// stay valid during the call only.
    public func withMutablePlane<Result>(_ index: Int, _ body: (UnsafeMutableRawBufferPointer) throws -> Result) rethrows -> Result {
        guard let storage else { preconditionFailure("a shared GPU buffer's pixels aren't in memory") }
        precondition(planes.indices.contains(index), "\(format) has no plane \(index)")
        return try withExtendedLifetime(self) {
            try body(UnsafeMutableRawBufferPointer(start: storage.bases[index], count: planes[index].byteCount))
        }
    }

    /// Where an element of a plane starts, from the plane's start.
    public func byteOffset(plane index: Int, x: Int, y: Int) -> Int {
        y * planes[index].bytesPerRow + x * format.planes[index].bytesPerElement
    }

    // MARK: Layout

    /// The planes and offsets of a buffer in one allocation, each row and
    /// plane aligned to `rowAlignment` bytes.
    static func layout(width: Int, height: Int, format: PixelFormat, rowAlignment: Int) -> (planes: [Plane], offsets: [Int], byteCount: Int) {
        precondition(width > 0 && height > 0, "a picture is at least a pixel")
        precondition(rowAlignment > 0 && rowAlignment & (rowAlignment - 1) == 0, "rows align to a power of two")
        func aligned(_ value: Int) -> Int { (value + rowAlignment - 1) & ~(rowAlignment - 1) }
        var planes: [Plane] = [], offsets: [Int] = []
        var offset = 0
        for plane in format.planes {
            let size = plane.size(width: width, height: height)
            let described = Plane(width: size.width, height: size.height, bytesPerRow: aligned(size.width * plane.bytesPerElement))
            planes.append(described)
            offsets.append(offset)
            offset = aligned(offset + described.byteCount)
        }
        return (planes, offsets, offset)
    }
}

// MARK: - Memory

/// The memory a buffer's planes are in: one allocation of its own, or
/// another library's planes.
final class PixelStorage: @unchecked Sendable {

    /// Where each plane starts.
    let bases: [UnsafeMutableRawPointer]

    /// The allocation's size, for a pool to reuse; 0 for memory that isn't
    /// this storage's.
    let byteCount: Int

    private let release: (@Sendable () -> Void)?

    /// One allocation, with planes at `offsets`.
    init(byteCount: Int, offsets: [Int], alignment: Int) {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(byteCount, 1), alignment: max(alignment, 16))
        let address = UInt(bitPattern: memory)
        self.bases = offsets.map { memory + $0 }
        self.byteCount = byteCount
        self.release = { UnsafeMutableRawPointer(bitPattern: address)?.deallocate() }
    }

    init(bases: [UnsafeMutableRawPointer], release: @escaping @Sendable () -> Void) {
        self.bases = bases
        self.byteCount = 0
        self.release = release
    }

    deinit {
        release?()
    }

    /// Black: luma at its lowest and chroma at its middle for YUV, zero
    /// (transparent black, premultiplied) for RGB.
    func clear(format: PixelFormat, planes: [PixelBuffer.Plane]) {
        for (index, plane) in planes.enumerated() {
            let base = bases[index]
            guard format.isYUV, index > 0 else {
                base.initializeMemory(as: UInt8.self, repeating: 0, count: plane.byteCount)
                continue
            }
            // Chroma's middle value: 128 for 8 bits, 512 in the high bits
            // of 16 for 10.
            if format.bitsPerComponent > 8 {
                let middle = UInt16(1 << (format.bitsPerComponent - 1)) << (16 - format.bitsPerComponent)
                base.initializeMemory(as: UInt16.self, repeating: middle.littleEndian, count: plane.byteCount / 2)
            } else {
                base.initializeMemory(as: UInt8.self, repeating: 128, count: plane.byteCount)
            }
        }
    }
}

// MARK: - Shared GPU buffers

/// A GPU buffer shared as dma-bufs: a file descriptor, offset and row
/// stride for each plane, and the layout modifier the buffer was made with.
public struct DMABuffer: Sendable {

    public struct Plane: Hashable, Sendable {

        public var fileDescriptor: Int32

        /// Where the plane starts in the descriptor's memory.
        public var offset: Int

        public var bytesPerRow: Int

        public init(fileDescriptor: Int32, offset: Int = 0, bytesPerRow: Int) {
            self.fileDescriptor = fileDescriptor
            self.offset = offset
            self.bytesPerRow = bytesPerRow
        }
    }

    public var planes: [Plane]

    /// The DRM format modifier, which says how the GPU tiled the buffer;
    /// `DMABuffer.noModifier` for a buffer exported without one.
    public var modifier: UInt64

    /// `DRM_FORMAT_MOD_INVALID`.
    public static let noModifier: UInt64 = 0x00ff_ffff_ffff_ffff

    public init(planes: [Plane], modifier: UInt64 = DMABuffer.noModifier) {
        self.planes = planes
        self.modifier = modifier
    }

    /// Closes each distinct descriptor once: planes often share one.
    func closeFileDescriptors() {
        for descriptor in Set(planes.map(\.fileDescriptor)) where descriptor >= 0 {
            close(descriptor)
        }
    }
}
