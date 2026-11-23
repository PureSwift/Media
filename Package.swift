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
///   buffers, on FFmpeg's libavcodec (`CFFmpeg`), and converting them between
///   formats and sizes, on libswscale (`CFFmpegScale`).
/// - `AudioCodec`: decoding coded audio to linear PCM and encoding PCM, on
///   libavcodec, converted by libswresample (`CFFmpegResample`).
/// - `MediaFiles`: reading and writing media files and streams (MP4,
///   Matroska, WebM, MPEG-TS, HLS, and the rest FFmpeg knows) as tracks of
///   sample buffers, on FFmpeg's libavformat (`CFFmpegFormat`).
/// - `MediaPlayback`: playing a file or stream, its pictures in step with
///   its sound, through an `AudioOutput`.
/// - `MediaSDL`: an `AudioOutput` on SDL3's audio streams, from
///   PureSwift/SDL, as Cacao uses.
/// - `CoreMedia`, `AVFoundation` and `AVKit` (Linux only): the parts of
///   Apple's that play media (`CMTime`, `AVPlayer`, `VideoPlayer`), so
///   sources that import them compile, with the view on PureSwift/Cacao.
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
        .library(name: "AudioCodec", targets: ["AudioCodec"]),
        .library(name: "MediaFiles", targets: ["MediaFiles"]),
        .library(name: "MediaPlayback", targets: ["MediaPlayback"]),
        .library(name: "MediaSDL", targets: ["MediaSDL"]),
    ] + appleProducts,
    dependencies: [
        .package(url: "https://github.com/PureSwift/SDL.git", branch: "master"),
    ] + appleDependencies,
    targets: [
        .target(name: "MediaCore"),
        .target(name: "PixelBuffers", dependencies: ["MediaCore"]),
        // FFmpeg's libavcodec and libavutil, from the system.
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavcodec",
            providers: [.apt(["libavcodec-dev", "libavutil-dev"]), .brew(["ffmpeg"])]
        ),
        // FFmpeg's libswscale, from the system.
        .systemLibrary(
            name: "CFFmpegScale",
            pkgConfig: "libswscale",
            providers: [.apt(["libswscale-dev"]), .brew(["ffmpeg"])]
        ),
        .target(name: "VideoCodec", dependencies: ["MediaCore", "PixelBuffers", "CFFmpeg", "CFFmpegScale"]),
        // FFmpeg's libswresample, from the system.
        .systemLibrary(
            name: "CFFmpegResample",
            pkgConfig: "libswresample",
            providers: [.apt(["libswresample-dev"]), .brew(["ffmpeg"])]
        ),
        .target(name: "AudioCodec", dependencies: ["MediaCore", "CFFmpeg", "CFFmpegResample"]),
        // FFmpeg's libavformat, from the system.
        .systemLibrary(
            name: "CFFmpegFormat",
            pkgConfig: "libavformat",
            providers: [.apt(["libavformat-dev"]), .brew(["ffmpeg"])]
        ),
        .target(name: "MediaFiles", dependencies: ["MediaCore", "CFFmpegFormat"]),
        .target(name: "MediaPlayback", dependencies: ["MediaCore", "MediaFiles", "VideoCodec", "AudioCodec"]),
        // SDL3's C API, from PureSwift/SDL's `CSDL3`, which `SDL3Swift` brings.
        .target(name: "MediaSDL", dependencies: ["MediaCore", "MediaPlayback", .product(name: "SDL3Swift", package: "SDL")]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
        .testTarget(name: "PixelBuffersTests", dependencies: ["PixelBuffers"]),
        .testTarget(name: "VideoCodecTests", dependencies: ["VideoCodec"]),
        .testTarget(name: "AudioCodecTests", dependencies: ["AudioCodec"]),
        .testTarget(name: "MediaFilesTests", dependencies: ["MediaFiles", "VideoCodec"]),
        .testTarget(name: "MediaSDLTests", dependencies: ["MediaSDL", "MediaPlayback", "MediaFiles"]),
        .testTarget(name: "MediaPlaybackTests", dependencies: ["MediaPlayback", "MediaFiles", "VideoCodec", "AudioCodec", "PixelBuffers"]),
    ] + appleTargets
)

// MARK: - CoreMedia, AVFoundation and AVKit

// On Linux, `CoreMedia`, `AVFoundation` and `AVKit` modules play media with
// this package, shown by PureSwift/Cacao's SwiftUI, so sources that import
// them compile. On Apple's platforms they would clash with Apple's. Cacao
// needs Swift 6.4.
#if os(Linux)
var appleDependencies: [Package.Dependency] {
    [
        .package(url: "https://github.com/PureSwift/Cacao.git", branch: "develop"),
    ]
}
var appleProducts: [Product] {
    [
        .library(name: "CoreMedia", targets: ["CoreMedia"]),
        .library(name: "AVFoundation", targets: ["AVFoundation"]),
        .library(name: "AVKit", targets: ["AVKit"]),
    ]
}
var appleTargets: [Target] {
    [
        // `CMTime` and `CMTimeRange`.
        .target(name: "CoreMedia", dependencies: ["MediaCore"]),
        // `AVPlayer`, which decodes on a thread of its own and publishes
        // pictures to one of Cacao's external surfaces.
        .target(
            name: "AVFoundation",
            dependencies: [
                "CoreMedia", "MediaCore", "PixelBuffers", "VideoCodec", "MediaPlayback", "MediaSDL",
                .product(name: "CacaoRender", package: "Cacao"),
            ]
        ),
        // `VideoPlayer`, the view that shows a player's surface.
        .target(
            name: "AVKit",
            dependencies: [
                "AVFoundation",
                .product(name: "Cacao", package: "Cacao"),
                .product(name: "CacaoRender", package: "Cacao"),
            ]
        ),
        .testTarget(
            name: "AVFoundationTests",
            dependencies: [
                "CoreMedia", "AVFoundation", "AVKit", "MediaCore", "PixelBuffers", "VideoCodec", "MediaFiles",
                .product(name: "CacaoRender", package: "Cacao"),
                .product(name: "Cacao", package: "Cacao"),
            ]
        ),
    ]
}
#else
var appleDependencies: [Package.Dependency] { [] }
var appleProducts: [Product] { [] }
var appleTargets: [Target] { [] }
#endif
