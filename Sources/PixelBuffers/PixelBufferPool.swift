import MediaCore
import Synchronization

/// Reuses the memory of pixel buffers of one size and format: a decoder
/// makes a buffer for each frame, and when the last reference to one goes,
/// its memory comes back here for the next, rather than being freed.
///
/// A reused buffer's pixels are whatever the last picture left, so whoever
/// makes one writes all of it. The pool is safe to use from any thread.
public final class PixelBufferPool: Sendable {

    public let width: Int

    public let height: Int

    public let format: PixelFormat

    public let rowAlignment: Int

    /// How many unused buffers' memory the pool keeps; more is freed.
    public let maximumIdleCount: Int

    private let planes: [PixelBuffer.Plane]

    private let offsets: [Int]

    private let byteCount: Int

    private let idle = Mutex<[PixelStorage]>([])

    public init(width: Int, height: Int, format: PixelFormat, rowAlignment: Int = 64, maximumIdleCount: Int = 4) {
        self.width = width
        self.height = height
        self.format = format
        self.rowAlignment = rowAlignment
        self.maximumIdleCount = max(maximumIdleCount, 0)
        let layout = PixelBuffer.layout(width: width, height: height, format: format, rowAlignment: rowAlignment)
        (planes, offsets, byteCount) = (layout.planes, layout.offsets, layout.byteCount)
    }

    /// A buffer of the pool's size and format: an earlier buffer's memory
    /// when one is free, else new, black memory.
    public func makeBuffer(color: ColorInfo = ColorInfo()) -> PixelBuffer {
        let reused = idle.withLock { $0.popLast() }
        let storage = reused ?? {
            let storage = PixelStorage(byteCount: byteCount, offsets: offsets, alignment: rowAlignment)
            storage.clear(format: format, planes: planes)
            return storage
        }()
        return PixelBuffer(width: width, height: height, format: format, color: color, planes: planes, storage: storage, pool: self)
    }

    /// Memory from a buffer of the pool's that went, kept while there's
    /// room.
    func recycle(_ storage: PixelStorage) {
        guard storage.byteCount == byteCount else { return }
        idle.withLock { idle in
            if idle.count < maximumIdleCount { idle.append(storage) }
        }
    }

    /// How many unused buffers' memory the pool holds.
    public var idleCount: Int {
        idle.withLock { $0.count }
    }

    /// Frees the memory of buffers not in use.
    public func flush() {
        idle.withLock { $0.removeAll() }
    }
}
