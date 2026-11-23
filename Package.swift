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
    ],
    targets: [
        .target(name: "MediaCore"),
        .target(name: "PixelBuffers", dependencies: ["MediaCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
        .testTarget(name: "PixelBuffersTests", dependencies: ["PixelBuffers"]),
    ]
)
