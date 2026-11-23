// The color of video: where its primaries are, how its values map to light,
// how luma and chroma make RGB, and how much of the range its values use.
// Raw values are ITU-T H.273's code points, which MP4's `colr` boxes,
// H.264's, H.265's and AV1's bitstreams and FFmpeg all use.

/// The chromaticities of the red, green and blue primaries and the white
/// point.
public struct ColorPrimaries: RawRepresentable, Hashable, Sendable {

    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// HD video's, and sRGB's.
    public static let bt709 = ColorPrimaries(rawValue: 1)
    public static let unspecified = ColorPrimaries(rawValue: 2)
    /// SD video in 625-line (PAL) systems.
    public static let bt470BG = ColorPrimaries(rawValue: 5)
    /// SD video in 525-line (NTSC) systems.
    public static let smpte170M = ColorPrimaries(rawValue: 6)
    /// UHD and HDR video's wide gamut.
    public static let bt2020 = ColorPrimaries(rawValue: 9)
    /// Display P3's primaries (P3 with the D65 white point).
    public static let p3D65 = ColorPrimaries(rawValue: 12)
}

/// How coded values map to light.
public struct TransferFunction: RawRepresentable, Hashable, Sendable {

    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bt709 = TransferFunction(rawValue: 1)
    public static let unspecified = TransferFunction(rawValue: 2)
    public static let smpte170M = TransferFunction(rawValue: 6)
    public static let linear = TransferFunction(rawValue: 8)
    /// sRGB's.
    public static let sRGB = TransferFunction(rawValue: 13)
    public static let bt2020TenBit = TransferFunction(rawValue: 14)
    /// HDR10's perceptual quantizer.
    public static let pq = TransferFunction(rawValue: 16)
    /// Hybrid log-gamma, broadcast HDR's.
    public static let hlg = TransferFunction(rawValue: 18)
}

/// How luma and chroma values make RGB.
public struct MatrixCoefficients: RawRepresentable, Hashable, Sendable {

    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The values are RGB already.
    public static let identity = MatrixCoefficients(rawValue: 0)
    public static let bt709 = MatrixCoefficients(rawValue: 1)
    public static let unspecified = MatrixCoefficients(rawValue: 2)
    public static let bt470BG = MatrixCoefficients(rawValue: 5)
    /// SD video's (BT.601).
    public static let smpte170M = MatrixCoefficients(rawValue: 6)
    public static let bt2020NonConstant = MatrixCoefficients(rawValue: 9)
}

/// How much of the range of a component's values video uses.
public enum ColorRange: Hashable, Sendable {
    /// Video's limited range: 16 to 235 for 8-bit luma, 16 to 240 for
    /// chroma.
    case video
    /// All of it: 0 to 255 for 8 bits.
    case full
}

/// Where a chroma sample sits against the luma samples it covers, in
/// subsampled formats.
public enum ChromaLocation: Hashable, Sendable {
    /// Beside the top-left luma sample, halfway down: MPEG-2's, H.264's and
    /// H.265's default.
    case left
    /// Centered among the luma samples: JPEG's.
    case center
    /// On the top-left luma sample: BT.2020's.
    case topLeft
}

/// All of a picture's color.
public struct ColorInfo: Hashable, Sendable {

    public var primaries: ColorPrimaries

    public var transferFunction: TransferFunction

    public var matrix: MatrixCoefficients

    public var range: ColorRange

    /// Nil where the picture isn't subsampled, or nothing said.
    public var chromaLocation: ChromaLocation?

    public init(
        primaries: ColorPrimaries = .unspecified,
        transferFunction: TransferFunction = .unspecified,
        matrix: MatrixCoefficients = .unspecified,
        range: ColorRange = .video,
        chromaLocation: ChromaLocation? = nil
    ) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.matrix = matrix
        self.range = range
        self.chromaLocation = chromaLocation
    }

    /// HD video: BT.709 throughout, in video range.
    public static let bt709 = ColorInfo(primaries: .bt709, transferFunction: .bt709, matrix: .bt709, range: .video, chromaLocation: .left)

    /// sRGB pictures: BT.709's primaries, sRGB's transfer, full-range RGB.
    public static let sRGB = ColorInfo(primaries: .bt709, transferFunction: .sRGB, matrix: .identity, range: .full)
}
