import MediaCore

/// How a picture's pixels are laid out: its planes, what each holds, and how
/// finely.
///
/// Packed RGB formats have one plane with all of a pixel's components side
/// by side. YUV formats keep luma in a plane of its own and chroma in one
/// or two more, usually at half the resolution in each direction (4:2:0).
public struct PixelFormat: Hashable, Sendable, CustomStringConvertible {

    /// One plane of a format.
    public struct Plane: Hashable, Sendable {

        /// The bytes one element of the plane takes: a pixel of packed RGB,
        /// a luma sample, an interleaved Cb and Cr pair.
        public var bytesPerElement: Int

        /// How many pixels across and down one element covers: 1 for full
        /// resolution, 2 for chroma subsampled by half.
        public var horizontalSubsampling: Int

        public var verticalSubsampling: Int

        public init(bytesPerElement: Int, horizontalSubsampling: Int = 1, verticalSubsampling: Int = 1) {
            self.bytesPerElement = bytesPerElement
            self.horizontalSubsampling = horizontalSubsampling
            self.verticalSubsampling = verticalSubsampling
        }

        /// The plane's size in elements, for a picture of `width` by
        /// `height` pixels: rounded up, so odd sizes keep their last row and
        /// column.
        public func size(width: Int, height: Int) -> (width: Int, height: Int) {
            ((width + horizontalSubsampling - 1) / horizontalSubsampling, (height + verticalSubsampling - 1) / verticalSubsampling)
        }
    }

    /// The format's name, for descriptions.
    public var name: String

    public var planes: [Plane]

    /// Whether it holds luma and chroma rather than RGB.
    public var isYUV: Bool

    /// The significant bits of each component.
    public var bitsPerComponent: Int

    /// Its code in Linux's DRM, which shared GPU buffers carry
    /// (`drm_fourcc.h`); nil for a format DRM doesn't name.
    public var drmFormat: FourCharacterCode?

    public init(name: String, planes: [Plane], isYUV: Bool, bitsPerComponent: Int = 8, drmFormat: FourCharacterCode? = nil) {
        self.name = name
        self.planes = planes
        self.isYUV = isYUV
        self.bitsPerComponent = bitsPerComponent
        self.drmFormat = drmFormat
    }

    public var description: String { name }

    public var isPlanar: Bool { planes.count > 1 }

    // MARK: Formats

    /// Blue, green, red and alpha bytes, in that order, alpha
    /// premultiplied: what Cairo, Wayland and SDL draw in little-endian
    /// memory. DRM's ARGB8888.
    public static let bgra8 = PixelFormat(name: "BGRA", planes: [Plane(bytesPerElement: 4)], isYUV: false, drmFormat: "AR24")

    /// Red, green, blue and alpha bytes, in that order, alpha
    /// premultiplied: what OpenGL reads back. DRM's ABGR8888.
    public static let rgba8 = PixelFormat(name: "RGBA", planes: [Plane(bytesPerElement: 4)], isYUV: false, drmFormat: "AB24")

    /// 8-bit 4:2:0 YUV in two planes: luma, then Cb and Cr interleaved at
    /// half resolution. What hardware decoders produce. DRM's NV12.
    public static let nv12 = PixelFormat(
        name: "NV12",
        planes: [Plane(bytesPerElement: 1), Plane(bytesPerElement: 2, horizontalSubsampling: 2, verticalSubsampling: 2)],
        isYUV: true,
        drmFormat: "NV12"
    )

    /// 8-bit 4:2:0 YUV in three planes: luma, Cb, Cr, each chroma plane at
    /// half resolution. What software decoders produce. DRM's YUV420.
    public static let i420 = PixelFormat(
        name: "I420",
        planes: [
            Plane(bytesPerElement: 1),
            Plane(bytesPerElement: 1, horizontalSubsampling: 2, verticalSubsampling: 2),
            Plane(bytesPerElement: 1, horizontalSubsampling: 2, verticalSubsampling: 2),
        ],
        isYUV: true,
        drmFormat: "YU12"
    )

    /// 10-bit 4:2:0 YUV laid out as NV12, each sample in the high bits of
    /// 16, little-endian: HDR video's. DRM's P010.
    public static let p010 = PixelFormat(
        name: "P010",
        planes: [Plane(bytesPerElement: 2), Plane(bytesPerElement: 4, horizontalSubsampling: 2, verticalSubsampling: 2)],
        isYUV: true,
        bitsPerComponent: 10,
        drmFormat: "P010"
    )

    /// One 8-bit gray value a pixel. DRM's R8.
    public static let gray8 = PixelFormat(name: "Gray", planes: [Plane(bytesPerElement: 1)], isYUV: false, drmFormat: "R8  ")
}
