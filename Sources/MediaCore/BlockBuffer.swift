/// Bytes a sample is made of: coded video, compressed audio, PCM. Immutable,
/// so it is shared rather than copied: slicing one shares its memory, and
/// memory another library owns (a demuxer's packet) is wrapped without
/// copying, to be released when the last buffer over it goes.
public struct BlockBuffer: Sendable {

    /// The memory, and what gives it back.
    final class Storage: @unchecked Sendable {
        let base: UnsafeRawPointer?
        let count: Int
        let release: (@Sendable () -> Void)?

        init(base: UnsafeRawPointer?, count: Int, release: (@Sendable () -> Void)?) {
            self.base = base
            self.count = count
            self.release = release
        }

        deinit {
            release?()
        }
    }

    let storage: Storage

    /// The part of the storage this buffer is.
    let range: Range<Int>

    /// No bytes.
    public init() {
        self.init(bytes: [])
    }

    /// A copy of `bytes`.
    public init(bytes: some Sequence<UInt8>) {
        let array = Array(bytes)
        let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: max(array.count, 1), alignment: 16)
        array.withUnsafeBytes { memory.copyMemory(from: $0) }
        let base = UnsafeRawPointer(memory.baseAddress)
        storage = Storage(base: base, count: array.count, release: BlockBuffer.deallocating(memory))
        range = 0..<array.count
    }

    /// `count` bytes, which `initialize` writes once, in place.
    public init(count: Int, initializingWith initialize: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
        let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: max(count, 1), alignment: 16)
        do {
            try initialize(UnsafeMutableRawBufferPointer(rebasing: memory[0..<count]))
        } catch {
            memory.deallocate()
            throw error
        }
        storage = Storage(base: UnsafeRawPointer(memory.baseAddress), count: count, release: BlockBuffer.deallocating(memory))
        range = 0..<count
    }

    /// Memory another library owns, without copying it: it must stay as it
    /// is until `release` is called, once, when the last buffer over it
    /// goes.
    public init(bytesNoCopy bytes: UnsafeRawBufferPointer, release: @escaping @Sendable () -> Void) {
        storage = Storage(base: bytes.baseAddress, count: bytes.count, release: release)
        range = 0..<bytes.count
    }

    /// The bytes of several buffers, one after another, copied into one.
    public init(concatenating buffers: [BlockBuffer]) {
        guard buffers.count != 1 else {
            self = buffers[0]
            return
        }
        let total = buffers.reduce(0) { $0 + $1.count }
        self.init(count: total) { memory in
            var offset = 0
            for buffer in buffers {
                buffer.withUnsafeBytes { bytes in
                    UnsafeMutableRawBufferPointer(rebasing: memory[offset..<offset + bytes.count]).copyMemory(from: bytes)
                }
                offset += buffer.count
            }
        }
    }

    /// Frees memory this buffer allocated, by its address, which a
    /// sendable closure can hold.
    private static func deallocating(_ memory: UnsafeMutableRawBufferPointer) -> @Sendable () -> Void {
        let address = UInt(bitPattern: memory.baseAddress)
        return { UnsafeMutableRawPointer(bitPattern: address)?.deallocate() }
    }

    private init(storage: Storage, range: Range<Int>) {
        self.storage = storage
        self.range = range
    }

    public var count: Int { range.count }

    public var isEmpty: Bool { range.isEmpty }

    /// The bytes in `bounds`, counted from this buffer's start, sharing its
    /// memory.
    public subscript(bounds: Range<Int>) -> BlockBuffer {
        precondition(bounds.lowerBound >= 0 && bounds.upperBound <= count, "range out of bounds")
        return BlockBuffer(storage: storage, range: range.lowerBound + bounds.lowerBound..<range.lowerBound + bounds.upperBound)
    }

    /// Reads the bytes, which stay valid during the call only.
    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        guard let base = storage.base, !range.isEmpty else { return try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
        return try withExtendedLifetime(storage) {
            try body(UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count))
        }
    }

    /// A copy of the bytes.
    public var bytes: [UInt8] {
        withUnsafeBytes { Array($0) }
    }
}

extension BlockBuffer: Equatable {

    /// Buffers are equal when their bytes are.
    public static func == (lhs: BlockBuffer, rhs: BlockBuffer) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.storage === rhs.storage, lhs.range == rhs.range { return true }
        return lhs.withUnsafeBytes { a in rhs.withUnsafeBytes { b in a.elementsEqual(b) } }
    }
}
