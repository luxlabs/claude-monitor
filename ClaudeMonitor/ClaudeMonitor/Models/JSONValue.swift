import Foundation

/// A parsed JSON value. Session files are decoded through it so the lenient,
/// type-checked field access of state.py (`_num`, `_int`, `_str`, `or`
/// fallbacks) can be mirrored exactly: a field with an unexpected type falls
/// back to its default instead of failing the whole file.
enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // JSONDecoder never reads a number as Bool nor a Bool as a number,
        // so `true` stays a bool (Python's `_num`/`_int` reject bools too).
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string, if this is a string (`_str`).
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The number, if this is a number and not a bool (`_num`).
    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// `int(value)` for a number (truncates toward zero), else nil (`_int`).
    var intValue: Int? {
        guard case .number(let n) = self, n.isFinite, abs(n) < 9.0e18 else { return nil }
        return Int(n)
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Python truthiness (`if value:` / `value or default`).
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): !s.isEmpty
        case .array(let a): !a.isEmpty
        case .object(let o): !o.isEmpty
        }
    }
}

/// ISO-8601 timestamps as written by Python's `datetime.isoformat()`.
///
/// `isoformat()` omits the fractional part when microseconds are 0, so both
/// "2026-10-11T07:07:39+00:00" and "2026-10-11T07:07:40.500000+00:00" occur;
/// `ISO8601DateFormatter` needs a different configuration for each (and goes
/// through ICU, which is slow), hence this small parser. Mirrors
/// `state.parse_iso`: `datetime.fromisoformat(value).timestamp()`.
enum ISOTime {
    /// Seconds since the epoch, or nil if `text` is not a valid timestamp.
    /// Accepts `YYYY-MM-DD[(T| )HH[:MM[:SS[(.|,)fraction]]]][Z|±HH[[:]MM[[:]SS]]]`;
    /// without an offset the time is local, as in Python.
    static func parse(_ text: String) -> Double? {
        let u = Array(text.utf8)
        var i = 0

        func digits(_ count: Int) -> Int? {
            guard i + count <= u.count else { return nil }
            var value = 0
            for k in 0..<count {
                let c = u[i + k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            i += count
            return value
        }
        func eat(_ char: Character) -> Bool {
            guard i < u.count, let ascii = char.asciiValue, u[i] == ascii else { return false }
            i += 1
            return true
        }

        guard let year = digits(4), eat("-"), let month = digits(2), eat("-"), let day = digits(2) else {
            return nil
        }
        var hour = 0, minute = 0, second = 0, micros = 0
        if i < u.count, eat("T") || eat("t") || eat(" ") {
            guard let h = digits(2) else { return nil }
            hour = h
            if eat(":") {
                guard let m = digits(2) else { return nil }
                minute = m
                if eat(":") {
                    guard let s = digits(2) else { return nil }
                    second = s
                    if eat(".") || eat(",") {
                        var count = 0
                        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 {
                            if count < 6 { micros = micros * 10 + Int(u[i] - 0x30) }
                            count += 1
                            i += 1
                        }
                        guard count > 0 else { return nil }
                        for _ in count..<max(count, 6) { micros *= 10 }  // pad to microseconds
                    }
                }
            }
        }

        var offset: Int?
        if i < u.count {
            if eat("Z") || eat("z") {
                offset = 0
            } else if u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") {
                let sign = u[i] == UInt8(ascii: "-") ? -1 : 1
                i += 1
                guard let oh = digits(2) else { return nil }
                var om = 0, os = 0
                if eat(":") {
                    guard let m = digits(2) else { return nil }
                    om = m
                    if eat(":") {
                        guard let s = digits(2) else { return nil }
                        os = s
                    }
                } else if i < u.count {
                    guard let m = digits(2) else { return nil }
                    om = m
                    if i < u.count {
                        guard let s = digits(2) else { return nil }
                        os = s
                    }
                }
                guard oh < 24, om < 60, os < 60 else { return nil }
                offset = sign * (oh * 3600 + om * 60 + os)
            } else {
                return nil
            }
        }
        guard i == u.count else { return nil }
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year, month),
              hour < 24, minute < 60, second < 60 else { return nil }

        var seconds = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
        if let offset {
            seconds -= offset
        } else {
            let guess = Date(timeIntervalSince1970: Double(seconds))
            seconds -= TimeZone.current.secondsFromGMT(for: guess)
        }
        // Same arithmetic as timedelta.total_seconds(): exact integer
        // microseconds, then one correctly rounded division.
        return Double(seconds * 1_000_000 + micros) / 1_000_000
    }

    static func date(_ text: String) -> Date? {
        parse(text).map { Date(timeIntervalSince1970: $0) }
    }

    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
