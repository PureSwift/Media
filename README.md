# Media

Multimedia library for Swift: time-based media for Linux first, building on
any platform Swift does.

| Target | What it is |
| --- | --- |
| `MediaCore` | Media time and time ranges, media and codec types, color, format descriptions, and sample buffers: the values the other targets pass around. No dependencies. |
| `PixelBuffers` | Pictures in memory or in GPU buffers shared as dma-bufs, in packed and planar formats (BGRA, RGBA, NV12, I420, P010, gray), with their color, and pools that reuse them. |

Coming next: decoding and encoding on libavcodec, demuxing and muxing on
libavformat, playback with audio on SDL3, and a player view for Cacao.

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

## Building

Swift 6.0 or later. On Apple platforms, macOS 15, iOS 18, tvOS 18, watchOS 11
or visionOS 2, for the standard library's `Mutex`.

```sh
swift build
swift test
```
