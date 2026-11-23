import Cacao
import Testing
@testable import AVKit

/// What the view that shows a player's surface reads from it. The view's
/// layout isn't tested here: Cacao's view graph is its own package's.
@Suite(.serialized) struct VideoPlayerTests {

    @Test func timesAreWrittenAsMinutesAndSeconds() {
        #expect(VideoPlayerTime.text(0) == "0:00")
        #expect(VideoPlayerTime.text(59.9) == "0:59")
        #expect(VideoPlayerTime.text(75) == "1:15")
        #expect(VideoPlayerTime.text(3725) == "1:02:05")
        #expect(VideoPlayerTime.text(.nan) == "0:00")
    }

    @Test func theModelReadsThePlayer() async throws {
        let movie = try Movie()
        let player = AVPlayer(url: movie.url)
        let model = PlayerModel(player: player)
        let changes = Shared(0)
        let subscription = model.objectWillChange.subscribe { changes.update { $0 += 1 } }
        #expect(await eventually { model.duration != nil })
        #expect(model.aspectRatio == 2)
        #expect(!model.isPlaying)
        model.seek(to: 0.5)
        #expect(await eventually { model.time == 0.5 })
        model.togglePlaying()
        #expect(model.isPlaying)
        model.togglePlaying()
        #expect(!model.isPlaying)
        #expect(changes.value >= 3)
        _ = subscription
    }
}
