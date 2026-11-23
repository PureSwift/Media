import MediaCore
import Testing

@Suite struct MediaTimeTests {

    @Test func timesAreEqualWhateverTheirScale() {
        #expect(MediaTime(value: 1, timescale: 2) == MediaTime(value: 2, timescale: 4))
        #expect(MediaTime(value: 1, timescale: 2).hashValue == MediaTime(value: 2, timescale: 4).hashValue)
        #expect(MediaTime(value: 0, timescale: 30) == .zero)
        #expect(MediaTime(value: 1, timescale: 3) != MediaTime(value: 333, timescale: 1000))
    }

    @Test func timesCompareExactly() {
        #expect(MediaTime(value: 1, timescale: 3) > MediaTime(value: 333_333_333, timescale: 1_000_000_000))
        #expect(MediaTime(value: -1, timescale: 2) < .zero)
        // Values whose cross products overflow 64 bits still compare.
        #expect(MediaTime(value: .max, timescale: 2) > MediaTime(value: .max, timescale: 3))
    }

    @Test func specialTimesOrderAroundNumbers() {
        let ordered: [MediaTime] = [.negativeInfinity, MediaTime(value: -5, timescale: 1), .zero, .positiveInfinity, .indefinite, .invalid]
        #expect(ordered == ordered.sorted())
        #expect(MediaTime.invalid == .invalid)
        #expect(MediaTime(value: 1, timescale: 0) == .invalid)
    }

    @Test func addsAcrossScalesExactly() {
        let frame = MediaTime(value: 1, timescale: 30)
        let sample = MediaTime(value: 1, timescale: 48000)
        let sum = frame + sample
        #expect(sum.timescale == 48000)
        #expect(sum.value == 1601)
        #expect(!sum.hasBeenRounded)
        #expect(frame - frame == .zero)
        #expect(frame * 30 == MediaTime(value: 1, timescale: 1))
    }

    @Test func addsInTheFinerScaleWhenTheCommonOneIsTooLarge() {
        let a = MediaTime(value: 1, timescale: 1_000_000_007)
        let b = MediaTime(value: 1, timescale: 999_999_937)
        let sum = a + b
        #expect(sum.timescale == 1_000_000_007)
        #expect(sum.hasBeenRounded)
    }

    @Test func roundsAsAsked() {
        let third = MediaTime(value: 1, timescale: 3)
        #expect(third.converted(to: 10).value == 3)
        #expect(third.converted(to: 10, rounding: .awayFromZero).value == 4)
        #expect(third.converted(to: 10, rounding: .towardZero).value == 3)
        #expect((-third).converted(to: 10, rounding: .towardNegativeInfinity).value == -4)
        #expect((-third).converted(to: 10, rounding: .towardPositiveInfinity).value == -3)
        #expect(MediaTime(value: 1, timescale: 2).converted(to: 1).value == 1)
        #expect(MediaTime(value: -1, timescale: 2).converted(to: 1).value == -1)
        #expect(third.converted(to: 10).hasBeenRounded)
        #expect(!MediaTime(value: 1, timescale: 2).converted(to: 10).hasBeenRounded)
    }

    @Test func overflowBecomesInfinity() {
        let large = MediaTime(value: .max / 2, timescale: 1)
        #expect(large.converted(to: 1000) == .positiveInfinity)
        #expect((-large).converted(to: 1000) == .negativeInfinity)
        #expect(MediaTime(value: .max, timescale: 1) + MediaTime(value: 1, timescale: 1) == .positiveInfinity)
    }

    @Test func specialTimesAbsorbNumbers() {
        let second = MediaTime(value: 1, timescale: 1)
        #expect(MediaTime.positiveInfinity + second == .positiveInfinity)
        #expect(MediaTime.indefinite + second == .indefinite)
        #expect(MediaTime.positiveInfinity + .negativeInfinity == .invalid)
        #expect(MediaTime.invalid + second == .invalid)
        #expect(-MediaTime.positiveInfinity == .negativeInfinity)
    }

    @Test func convertsSeconds() {
        let time = MediaTime(seconds: 1.5, timescale: 600)
        #expect(time.value == 900)
        #expect(!time.hasBeenRounded)
        #expect(time.seconds == 1.5)
        #expect(MediaTime(seconds: .infinity, timescale: 600) == .positiveInfinity)
        #expect(MediaTime(seconds: .nan, timescale: 600) == .invalid)
        #expect(MediaTime(seconds: 0.1, timescale: 3).hasBeenRounded)
        #expect(MediaTime.indefinite.seconds.isNaN)
    }
}

@Suite struct MediaTimeRangeTests {

    private func range(_ start: Int64, _ duration: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(value: start, timescale: 10), duration: MediaTime(value: duration, timescale: 10))
    }

    @Test func holdsItsStartAndNotItsEnd() {
        let r = range(10, 5)
        #expect(r.contains(MediaTime(value: 10, timescale: 10)))
        #expect(r.contains(MediaTime(value: 14, timescale: 10)))
        #expect(!r.contains(MediaTime(value: 15, timescale: 10)))
        #expect(!range(10, 0).contains(MediaTime(value: 10, timescale: 10)))
        #expect(r.contains(range(11, 2)))
        #expect(!r.contains(range(11, 5)))
    }

    @Test func intersectsAndJoins() {
        #expect(range(0, 10).intersection(range(5, 10)) == range(5, 5))
        let apart = range(0, 2).intersection(range(5, 2))
        #expect(apart.isEmpty)
        #expect(apart.start == MediaTime(value: 5, timescale: 10))
        #expect(range(0, 2).union(range(5, 2)) == range(0, 7))
    }

    @Test func everythingHasNoEnd() {
        #expect(MediaTimeRange.everything.end == .positiveInfinity)
        #expect(MediaTimeRange.everything.contains(MediaTime(value: -1_000_000, timescale: 1)))
        #expect(!MediaTimeRange.invalid.isValid)
        #expect(!MediaTimeRange(start: .zero, duration: MediaTime(value: -1, timescale: 1)).isValid)
    }
}
