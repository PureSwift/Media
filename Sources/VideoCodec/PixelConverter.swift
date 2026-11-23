import CFFmpeg
import CFFmpegScale
import MediaCore
import PixelBuffers

/// Converts pictures between pixel formats and sizes, on libswscale: a
/// decoder's YUV to the BGRA or RGBA a view shows, with the picture's own
/// matrix and range.
///
/// It takes pictures of any format and size this library describes, in
/// memory, and makes each again, from a pool, in the format and size it was
/// made for. A converter is for one thread at a time.
public final class PixelConverter {

    /// The format it converts to.
    public let format: PixelFormat

    /// The size it converts to; nil keeps each picture's.
    public let size: (width: Int, height: Int)?

    private let ffmpegFormat: AVPixelFormat

    private var context: OpaquePointer?

    /// What the context was set up for.
    private var key: Key?

    private var pool: PixelBufferPool?

    private struct Key: Equatable {
        var width: Int
        var height: Int
        var format: PixelFormat
        var matrix: MatrixCoefficients
        var range: ColorRange
        var outputWidth: Int
        var outputHeight: Int
    }

    /// A converter to `format`, at `width` by `height`, or each picture's
    /// own size.
    public init(to format: PixelFormat, width: Int? = nil, height: Int? = nil) throws {
        guard let ffmpegFormat = format.ffmpegFormat else { throw VideoCodecError.unsupportedPixelFormat(format.name) }
        self.format = format
        self.ffmpegFormat = ffmpegFormat
        if let width, let height {
            self.size = (width, height)
        } else {
            self.size = nil
        }
    }

    deinit {
        sws_freeContext(context)
    }

    /// The picture, converted into a buffer of its own.
    public func convert(_ picture: PixelBuffer) throws -> PixelBuffer {
        let (width, height) = size ?? (picture.width, picture.height)
        if pool?.width != width || pool?.height != height {
            pool = PixelBufferPool(width: width, height: height, format: format)
        }
        let output = pool!.makeBuffer(color: outputColor(for: picture.color))
        try convert(picture, into: output)
        return output
    }

    /// The picture, converted into `output`, which is in the converter's
    /// format, at any size.
    public func convert(_ picture: PixelBuffer, into output: PixelBuffer) throws {
        guard picture.isInMemory, output.isInMemory, output.format == format else { throw VideoCodecError.mismatchedPicture }
        guard let sourceFormat = picture.format.ffmpegFormat else { throw VideoCodecError.unsupportedPixelFormat(picture.format.name) }
        let context = try prepare(for: picture, sourceFormat: sourceFormat, output: output)
        try withPlanes(of: picture) { sources in
            try withPlanes(of: output) { destinations in
                var sourcePlanes: [UnsafePointer<UInt8>?] = sources.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
                var sourceStrides: [Int32] = picture.planes.map { Int32($0.bytesPerRow) }
                var destinationPlanes: [UnsafeMutablePointer<UInt8>?] = destinations.map { $0.assumingMemoryBound(to: UInt8.self) }
                var destinationStrides: [Int32] = output.planes.map { Int32($0.bytesPerRow) }
                // libswscale reads four of each.
                while sourcePlanes.count < 4 { sourcePlanes.append(nil); sourceStrides.append(0) }
                while destinationPlanes.count < 4 { destinationPlanes.append(nil); destinationStrides.append(0) }
                let rows = sws_scale(context, sourcePlanes, sourceStrides, 0, Int32(picture.height), destinationPlanes, destinationStrides)
                guard rows > 0 else { throw VideoCodecError.ffmpeg(rows) }
            }
        }
    }

    /// The context for this picture and output, made again when either
    /// changes.
    private func prepare(for picture: PixelBuffer, sourceFormat: AVPixelFormat, output: PixelBuffer) throws -> OpaquePointer {
        let matrix = picture.color.matrix == .unspecified
            ? (picture.height >= 720 ? MatrixCoefficients.bt709 : .smpte170M) : picture.color.matrix
        let key = Key(width: picture.width, height: picture.height, format: picture.format, matrix: matrix,
                      range: picture.color.range, outputWidth: output.width, outputHeight: output.height)
        if let context, key == self.key { return context }
        guard let made = sws_getCachedContext(
            context, Int32(picture.width), Int32(picture.height), sourceFormat,
            Int32(output.width), Int32(output.height), ffmpegFormat, SWS_BILINEAR, nil, nil, nil
        ) else {
            throw VideoCodecError.unsupportedPixelFormat("\(picture.format.name) to \(format.name)")
        }
        context = made
        let space: Int32 = switch matrix {
        case .bt709: SWS_CS_ITU709
        case .bt2020NonConstant: SWS_CS_BT2020
        case .smpte170M, .bt470BG: SWS_CS_ITU601
        default: SWS_CS_DEFAULT
        }
        // YUV in to RGB out: the picture's matrix and range, full-range RGB.
        let coefficients = sws_getCoefficients(space)
        sws_setColorspaceDetails(made, coefficients, picture.color.range == .full ? 1 : 0,
                                 coefficients, format.isYUV ? (picture.color.range == .full ? 1 : 0) : 1, 0, 1 << 16, 1 << 16)
        self.key = key
        return made
    }

    /// The color of a picture converted to this format.
    private func outputColor(for color: ColorInfo) -> ColorInfo {
        guard !format.isYUV else { return color }
        return ColorInfo(primaries: color.primaries, transferFunction: color.transferFunction, matrix: .identity, range: .full)
    }
}

/// Every plane's memory at once.
private func withPlanes<Result>(of picture: PixelBuffer, _ body: ([UnsafeMutableRawPointer]) throws -> Result) throws -> Result {
    func nest(_ index: Int, _ bases: [UnsafeMutableRawPointer]) throws -> Result {
        guard index < picture.planes.count else { return try body(bases) }
        return try picture.withMutablePlane(index) { plane in
            guard let base = plane.baseAddress else { throw VideoCodecError.mismatchedPicture }
            return try nest(index + 1, bases + [base])
        }
    }
    return try nest(0, [])
}
