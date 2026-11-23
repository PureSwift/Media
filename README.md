# Media

Multimedia library for Swift: time-based media for Linux first, building on
any platform Swift does.

| Target | What it is |
| --- | --- |
| `MediaCore` | Media time and time ranges, media and codec types, color, format descriptions, and sample buffers: the values the other targets pass around. No dependencies. |
| `PixelBuffers` | Pictures in memory or in GPU buffers shared as dma-bufs, in packed and planar formats (BGRA, RGBA, NV12, I420, P010, gray), with their color, and pools that reuse them. |
| `VideoCodec` | Decoding coded video (H.264, HEVC, AV1, VP8, VP9, MPEG-4, JPEG, ProRes) to pixel buffers, and encoding pixel buffers, on FFmpeg's libavcodec. |

Coming next: demuxing and muxing on libavformat, playback with audio on
SDL3, and a player view for Cacao.

## MediaCore

`MediaTime` is a whole number of units of `1 / timescale` seconds, exact
across scales:

```swift
let frame = MediaTime(value: 1, timescale: 30)
let sample = MediaTime(value: 1, timescale: 48000)
let sum = frame + sample                  // 1601/48000, exact
let rounded = frame.converted(to: 1000)   // 33/1000, rounded
```

A `SampleBuffer` carries one frame of video, or packets or PCM frames of
audio: their bytes in a `BlockBuffer` (shared, not copied, and able to wrap
another library's memory), or a decoded picture; their `FormatDescription`;
their `SampleTiming`; and flags such as `.sync` for a keyframe.

## PixelBuffers

```swift
let pool = PixelBufferPool(width: 1920, height: 1080, format: .nv12)
let picture = pool.makeBuffer(color: .bt709)
picture.withMutablePlane(0) { luma in
    // Write the luma plane: picture.planes[0].bytesPerRow apart.
}
```

A buffer from a pool returns its memory to the pool when the last reference
to it goes. A decoder's own frames can be wrapped without copying
(`planesNoCopy:release:`), and a GPU buffer is described by its dma-bufs
(`DMABuffer`), which the buffer then owns.

## VideoCodec

```swift
let decoder = try VideoDecoder(format: track.format)   // with its avcC or hvcC
for sample in samples {                                // in decode order
    for picture in try decoder.decode(sample) {        // in presentation order
        show(picture.image as! PixelBuffer, at: picture.presentationTime)
    }
}
let rest = try decoder.finish()
```

A decoded picture's pixels are libavcodec's own frame, wrapped, not copied,
and freed when the pixel buffer goes; its color and timing come with it.
`VideoEncoder` takes pixel buffers in presentation order and gives coded
samples in decode order, with a `format` that holds the codec's
configuration record, as a file's track needs.

## Building

Swift 6.0 or later. On Apple platforms, macOS 15, iOS 18, tvOS 18, watchOS 11
or visionOS 2, for the standard library's `Mutex`.

```sh
swift build
swift test
```

`VideoCodec` needs FFmpeg's libavcodec and libavutil (7 or later) where
pkg-config finds them: `apt install libavcodec-dev libavutil-dev` on Debian
and Ubuntu, `brew install ffmpeg` on macOS. Without root, Debian's packages
can be unpacked instead (`apt-get download libavcodec-dev libavutil-dev
libswresample-dev`, then `dpkg -x` each), with `PKG_CONFIG_PATH` set to their
`pkgconfig` folder and its paths pointed there.
