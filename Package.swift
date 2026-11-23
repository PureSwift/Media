// swift-tools-version: 6.0
import PackageDescription

/// Media: Swift libraries for time-based media, Linux first and building on
/// any platform Swift does.
///
/// - `MediaCore`: media time and time ranges, media and codec types, format
///   descriptions, and sample buffers: the values every other target passes
///   around. No dependencies.
/// - `PixelBuffers`: images in memory or in shared GPU buffers, in packed
///   and planar pixel formats, with their color, and pools that reuse them.
///   Depends on `MediaCore` only.
/// - `VideoCodec`: decoding coded video to pixel buffers and encoding pixel
///   buffers, on FFmpeg's libavcodec (`CFFmpeg`).
let package = Package(
    name: "Media",
    platforms: [
        // The standard library's Mutex.
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "PixelBuffers", targets: ["PixelBuffers"]),
        .library(name: "VideoCodec", targets: ["VideoCodec"]),
    ],
    targets: [
        .target(name: "MediaCore"),
        .target(name: "PixelBuffers", dependencies: ["MediaCore"]),
        // FFmpeg's libavcodec and libavutil, from the system.
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavcodec",
            providers: [.apt(["libavcodec-dev", "libavutil-dev"]), .brew(["ffmpeg"])]
        ),
        .target(name: "VideoCodec", dependencies: ["MediaCore", "PixelBuffers", "CFFmpeg"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
        .testTarget(name: "PixelBuffersTests", dependencies: ["PixelBuffers"]),
        .testTarget(name: "VideoCodecTests", dependencies: ["VideoCodec"]),
    ]
)
