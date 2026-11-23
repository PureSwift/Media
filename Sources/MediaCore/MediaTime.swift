/// A point or length in media time: a whole number of units, `value`, of
/// `1 / timescale` seconds each. A frame of 30 fps video is `1/30`, and
/// 48 kHz audio counts in `1/48000`.
///
/// Times are exact: `1/2` equals `2/4`, adding times of different scales
/// keeps them exact when it can, and a conversion to another scale rounds
/// only as asked. Besides numbers, a time can be positive or negative
/// infinity, indefinite (a live stream's duration), or invalid (nothing
/// known).
public struct MediaTime: Sendable {

    /// What kind of time this is.
    public enum Kind: Hashable, Sendable {
        /// `value / timescale` seconds.
        case numeric
        case positiveInfinity
        case negativeInfinity
        /// A time that exists but isn't known, as a live stream's duration.
        case indefinite
        /// No time at all.
        case invalid
    }

    /// The number of units. Meaningful only for numeric times.
    public var value: Int64

    /// The units per second. Positive for numeric times.
    public var timescale: Int32

    public var kind: Kind

    /// Whether arithmetic or a conversion rounded on the way to this time.
    public var hasBeenRounded: Bool

    /// `value / timescale` seconds; invalid if `timescale` isn't positive.
    public init(value: Int64, timescale: Int32) {
        guard timescale > 0 else {
            self = .invalid
            return
        }
        self.value = value
        self.timescale = timescale
        self.kind = .numeric
        self.hasBeenRounded = false
    }

    /// The nearest time to `seconds` in units of `1 / timescale`; infinite
    /// or invalid for infinite or NaN seconds.
    public init(seconds: Double, timescale: Int32) {
        guard timescale > 0, !seconds.isNaN else {
            self = .invalid
            return
        }
        guard seconds.isFinite else {
            self = seconds > 0 ? .positiveInfinity : .negativeInfinity
            return
        }
        let scaled = (seconds * Double(timescale)).rounded()
        guard scaled.magnitude < 0x1p63 else {
            self = scaled > 0 ? .positiveInfinity : .negativeInfinity
            return
        }
        self.init(value: Int64(scaled), timescale: timescale)
        hasBeenRounded = scaled != seconds * Double(timescale)
    }

    private init(kind: Kind) {
        self.value = 0
        self.timescale = 0
        self.kind = kind
        self.hasBeenRounded = false
    }

    public static let zero = MediaTime(value: 0, timescale: 1)
    public static let invalid = MediaTime(kind: .invalid)
    public static let indefinite = MediaTime(kind: .indefinite)
    public static let positiveInfinity = MediaTime(kind: .positiveInfinity)
    public static let negativeInfinity = MediaTime(kind: .negativeInfinity)

    public var isValid: Bool { kind != .invalid }
    public var isNumeric: Bool { kind == .numeric }
    public var isIndefinite: Bool { kind == .indefinite }
    public var isInfinite: Bool { kind == .positiveInfinity || kind == .negativeInfinity }

    /// The time in seconds: infinite for infinities, NaN when it isn't a
    /// number.
    public var seconds: Double {
        switch kind {
        case .numeric: Double(value) / Double(timescale)
        case .positiveInfinity: .infinity
        case .negativeInfinity: -.infinity
        case .indefinite, .invalid: .nan
        }
    }
}

// MARK: - Converting

extension MediaTime {

    /// How a time that falls between two units goes to one of them.
    public enum Rounding: Hashable, Sendable {
        /// To the nearer, and away from zero when it's halfway.
        case halfAwayFromZero
        case towardZero
        case awayFromZero
        case towardPositiveInfinity
        case towardNegativeInfinity
    }

    /// The time in units of `1 / timescale`, rounded as asked when it falls
    /// between two of them. Times that aren't numbers keep their kind; an
    /// invalid scale makes an invalid time, and a value too large for the
    /// scale an infinity.
    public func converted(to timescale: Int32, rounding: Rounding = .halfAwayFromZero) -> MediaTime {
        guard isNumeric else { return self }
        guard timescale > 0 else { return .invalid }
        guard timescale != self.timescale else { return self }
        guard let (scaled, exact) = MediaTime.scale(value, by: Int64(timescale), over: Int64(self.timescale), rounding: rounding) else {
            return value < 0 ? .negativeInfinity : .positiveInfinity
        }
        var time = MediaTime(value: scaled, timescale: timescale)
        time.hasBeenRounded = hasBeenRounded || !exact
        return time
    }

    /// `value * multiplier / divisor`, rounded, and whether it was exact;
    /// nil if it doesn't fit 64 bits. `divisor` is positive.
    static func scale(_ value: Int64, by multiplier: Int64, over divisor: Int64, rounding: Rounding) -> (Int64, Bool)? {
        let product = value.multipliedFullWidth(by: multiplier)
        let negative = product.high < 0
        // The magnitude, divided as unsigned 128 bits.
        var high = UInt64(bitPattern: product.high), low = product.low
        if negative {
            low = ~low &+ 1
            high = ~high &+ (low == 0 ? 1 : 0)
        }
        let divisor = UInt64(divisor)
        guard high < divisor else { return nil }
        let (quotient, remainder) = divisor.dividingFullWidth((high, low))
        var magnitude = quotient
        if remainder != 0 {
            let up: Bool = switch rounding {
            case .halfAwayFromZero: remainder >= divisor - remainder
            case .towardZero: false
            case .awayFromZero: true
            case .towardPositiveInfinity: !negative
            case .towardNegativeInfinity: negative
            }
            if up { magnitude += 1 }
        }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            return (magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude), remainder == 0)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return (Int64(magnitude), remainder == 0)
    }
}

// MARK: - Arithmetic

extension MediaTime {

    /// The scale two times are added in: the smallest that holds both
    /// exactly, or the finer of the two when that doesn't fit, which rounds.
    private static func commonTimescale(_ a: Int32, _ b: Int32) -> (timescale: Int32, exact: Bool) {
        guard a != b else { return (a, true) }
        let lcm = Int64(a) / Int64(gcd(Int64(a), Int64(b))) * Int64(b)
        if lcm <= Int64(Int32.max) { return (Int32(lcm), true) }
        return (max(a, b), false)
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a.magnitude, b.magnitude)
        while b != 0 { (a, b) = (b, a % b) }
        return Int64(a)
    }

    /// The sum. Infinities and indefinite times absorb numbers; opposite
    /// infinities, and anything with an invalid time, make an invalid time.
    /// A sum too large for its scale is an infinity.
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        switch (lhs.kind, rhs.kind) {
        case (.invalid, _), (_, .invalid): return .invalid
        case (.positiveInfinity, .negativeInfinity), (.negativeInfinity, .positiveInfinity): return .invalid
        case (.indefinite, _), (_, .indefinite): return .indefinite
        case (.positiveInfinity, _), (_, .positiveInfinity): return .positiveInfinity
        case (.negativeInfinity, _), (_, .negativeInfinity): return .negativeInfinity
        case (.numeric, .numeric): break
        }
        let (timescale, exact) = commonTimescale(lhs.timescale, rhs.timescale)
        let a = lhs.converted(to: timescale), b = rhs.converted(to: timescale)
        guard a.isNumeric else { return a }
        guard b.isNumeric else { return b }
        let (sum, overflow) = a.value.addingReportingOverflow(b.value)
        guard !overflow else { return a.value < 0 ? .negativeInfinity : .positiveInfinity }
        var time = MediaTime(value: sum, timescale: timescale)
        time.hasBeenRounded = !exact || a.hasBeenRounded || b.hasBeenRounded
        return time
    }

    public static prefix func - (time: MediaTime) -> MediaTime {
        switch time.kind {
        case .numeric:
            guard time.value != .min else { return .positiveInfinity }
            var negated = time
            negated.value = -time.value
            return negated
        case .positiveInfinity: return .negativeInfinity
        case .negativeInfinity: return .positiveInfinity
        case .indefinite, .invalid: return time
        }
    }

    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        lhs + -rhs
    }

    public static func += (lhs: inout MediaTime, rhs: MediaTime) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout MediaTime, rhs: MediaTime) {
        lhs = lhs - rhs
    }

    /// The time `multiplier` times over, in the same scale.
    public static func * (lhs: MediaTime, multiplier: Int64) -> MediaTime {
        switch lhs.kind {
        case .numeric:
            let (product, overflow) = lhs.value.multipliedReportingOverflow(by: multiplier)
            guard !overflow else { return (lhs.value < 0) != (multiplier < 0) ? .negativeInfinity : .positiveInfinity }
            var time = lhs
            time.value = product
            return time
        case .positiveInfinity, .negativeInfinity:
            if multiplier == 0 { return .invalid }
            return multiplier < 0 ? -lhs : lhs
        case .indefinite, .invalid:
            return lhs
        }
    }
}

// MARK: - Comparing

extension MediaTime: Comparable, Hashable {

    /// Times compare by what they mean, whatever their scales: negative
    /// infinity, then numbers, positive infinity, indefinite and invalid
    /// times, which equal each other.
    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        compare(lhs, rhs) < 0
    }

    public static func == (lhs: MediaTime, rhs: MediaTime) -> Bool {
        compare(lhs, rhs) == 0
    }

    /// -1, 0 or 1.
    static func compare(_ lhs: MediaTime, _ rhs: MediaTime) -> Int {
        func rank(_ kind: Kind) -> Int {
            switch kind {
            case .negativeInfinity: 0
            case .numeric: 1
            case .positiveInfinity: 2
            case .indefinite: 3
            case .invalid: 4
            }
        }
        let ranks = (rank(lhs.kind), rank(rhs.kind))
        guard ranks.0 == 1, ranks.1 == 1 else { return ranks.0 < ranks.1 ? -1 : ranks.0 > ranks.1 ? 1 : 0 }
        // a/b against c/d: a*d against c*b, exactly.
        let left = lhs.value.multipliedFullWidth(by: Int64(rhs.timescale))
        let right = rhs.value.multipliedFullWidth(by: Int64(lhs.timescale))
        if left.high != right.high { return left.high < right.high ? -1 : 1 }
        if left.low != right.low { return left.low < right.low ? -1 : 1 }
        return 0
    }

    /// Equal times hash alike: a number by its value in lowest terms.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        guard isNumeric else { return }
        let divisor = MediaTime.gcd(value, Int64(timescale))
        hasher.combine(value / divisor)
        hasher.combine(Int64(timescale) / divisor)
    }
}

extension MediaTime: CustomStringConvertible {

    public var description: String {
        switch kind {
        case .numeric: "\(value)/\(timescale)\(hasBeenRounded ? " (rounded)" : "")"
        case .positiveInfinity: "+infinity"
        case .negativeInfinity: "-infinity"
        case .indefinite: "indefinite"
        case .invalid: "invalid"
        }
    }
}
