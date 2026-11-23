# Media

Multimedia library for Swift: time-based media for Linux first, building on
any platform Swift does.

| Target | What it is |
| --- | --- |
| `MediaCore` | Media time and time ranges, media and codec types, color, format descriptions, and sample buffers: the values the other targets pass around. No dependencies. |
| `PixelBuffers` | Pictures in memory or in GPU buffers shared as dma-bufs, in packed and planar formats (BGRA, RGBA, NV12, I420, P010, gray), with their color, and pools that reuse them. |
| `VideoCodec` | Decoding coded video (H.264, HEVC, AV1, VP8, VP9, MPEG-4, JPEG, ProRes) to pixel buffers, and encoding pixel buffers, on FFmpeg's libavcodec; converting pictures between formats and sizes, on libswscale. |
| `AudioCodec` | Decoding coded audio (AAC, Opus, MP3, FLAC, Vorbis, AC-3, E-AC-3, ALAC) to linear PCM in any layout, rate and channels, and encoding PCM, on libavcodec and libswresample. |
| `MediaFiles` | Reading tracks of sample buffers from files and streams (MP4, MOV, Matroska and WebM, MPEG-TS, HLS, Ogg, WAV…), seeking, and writing them to files, on FFmpeg's libavformat. |
| `MediaPlayback` | Playing a file or stream: its pictures in step with its sound, following the sound's output, or the host's clock without one, with pausing and seeking. |
| `MediaSDL` | `SDLAudioOutput`: a player's sound through SDL3's audio streams, from PureSwift/SDL, as Cacao uses. |
| `CoreMedia`, `AVFoundation`, `AVKit` (Linux only) | The parts of Apple's that play media: `CMTime`, `AVPlayer` and `AVPlayerItem`, and the `VideoPlayer` view for [Cacao](https://github.com/PureSwift/Cacao)'s SwiftUI, so sources that import them compile. |

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

`PixelConverter` makes a picture again in another format or size, with the
picture's own matrix and range: a decoder's YUV as the BGRA a view shows.

```swift
let converter = try PixelConverter(to: .bgra8)          // or width:height: to scale
let shown = try converter.convert(picture)              // from a pool
```

## AudioCodec

```swift
let decoder = try AudioDecoder(format: track.format,   // with its magic cookie
                               options: .init(layout: .float32, sampleRate: 48000))
for sample in samples {
    for pcm in try decoder.decode(sample) {            // sampleCount frames each
        play(pcm.data!, at: pcm.presentationTime)
    }
}

let encoder = try AudioEncoder(settings: .init(codec: .aac, sampleRate: 48000, channelLayout: .stereo))
let packets = try encoder.encode(pcm) + encoder.finish()
```

The decoder gives PCM converted by libswresample to the layout, rate and
channels asked for, or the audio's own. The encoder takes PCM in buffers of
any size and layout, and cuts it into the codec's frames; its `format` holds
the magic cookie a file's track needs.

## MediaFiles

```swift
let reader = try MediaReader(url: "movie.mp4")          // or an http(s) URL
let video = reader.tracks.first { $0.format.mediaType == .video }!
try reader.select(tracks: [video.id])
try reader.seek(to: MediaTime(value: 10, timescale: 1)) // to the keyframe before
while let (_, sample) = try reader.nextSample() {       // in decode order
    // Decode with VideoDecoder(format:), from video.format.
}

let writer = try MediaWriter(url: "out.mkv")            // container from the extension
let track = try writer.addTrack(.video(encoder.format), timescale: 30)
for sample in samples { try writer.write(sample, to: track) }
try writer.finish()
```

A sample read is libavformat's packet, wrapped, not copied. A sample written
is copied, and libavformat interleaves the tracks.

## MediaPlayback

```swift
let player = try Player(url: "movie.mkv", audioOutput: try SDLAudioOutput())
player.play()
// For each frame drawn:
if let picture = try player.update()?.image as? PixelBuffer {
    draw(picture)
}
player.seek(to: MediaTime(value: 30, timescale: 1))
```

`update` reads and decodes as far as playback needs, keeps half a second of
sound queued, and returns the latest picture due. Time follows the sound the
output reports played, or the host's clock when there's no sound, or once
it ends.

## AVKit

On Linux, sources written against Apple's AVKit compile, and show a player's
pictures in a Cacao app:

```swift
import AVKit
import SwiftUI

struct Movie: View {

    @State private var player = AVPlayer(url: URL(fileURLWithPath: "movie.mp4"))

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
    }
}
```

`AVPlayer` opens and decodes its item on a thread of its own, converts each
picture to BGRA and publishes it to one of Cacao's external surfaces; its
sound goes to SDL's default playback device. `VideoPlayer` fits the pictures
to the view, with a play and pause button, the time and a scrubber.

Unlike Apple's, there is no key-value observing (use a periodic time observer
and the item's `didPlayToEndTimeNotification`), an item plays at its own rate
only, seeks are always exact, and `play` at an item's end starts it again.

## Building

Swift 6.0 or later. On Apple platforms, macOS 15, iOS 18, tvOS 18, watchOS 11
or visionOS 2, for the standard library's `Mutex`.

```sh
swift build
swift test
```

On Linux, the package also takes [Cacao](https://github.com/PureSwift/Cacao),
for `AVFoundation` and `AVKit`, which needs Swift 6.4 and Cairo, fontconfig
and FreeType (`libcairo2-dev libfontconfig-dev libfreetype-dev`).

`VideoCodec` needs FFmpeg's libavcodec, libavutil and libswscale (7 or later)
where pkg-config finds them, `MediaFiles` libavformat too, `AudioCodec`
libswresample, and `MediaSDL` SDL 3: `apt install libavcodec-dev libavformat-dev libavutil-dev
libswscale-dev libswresample-dev libsdl3-dev` on Debian and Ubuntu (SDL 3.2 or later),
`brew install ffmpeg sdl3` on macOS. Without root, Debian's packages
can be unpacked instead (`apt-get download libavcodec-dev libavformat-dev
libavutil-dev libswresample-dev`, then `dpkg -x` each), with `PKG_CONFIG_PATH` set to their
`pkgconfig` folder and its paths pointed there.
