import Foundation

/// Wetterdaten: eine Folge aus Kennbuchstabe und Wert fester Länge
/// (`c220s004g005t077r000p000P000h50b09900`). Punkte oder Leerzeichen statt
/// Ziffern heissen «kein Wert».
enum APRSWeatherDecoder {
    private static let timestampLength = 8

    /// `_MMDDHHMM` gefolgt von den Wetterfeldern.
    static func decodePositionless(_ payload: ArraySlice<UInt8>) -> APRSWeatherReport? {
        var rest = payload.dropFirst()
        guard rest.count >= timestampLength else { return nil }
        let stamp = Array(rest.prefix(timestampLength))
        guard let month = number(stamp[0..<2]), let day = number(stamp[2..<4]),
              let hour = number(stamp[4..<6]), let minute = number(stamp[6..<8]) else { return nil }
        rest = rest.dropFirst(timestampLength)
        let valid = (1...12).contains(month) && (1...31).contains(day) && hour < 24 && minute < 60
        guard let (weather, comment) = decodeFields(rest, allowsWindPrefix: false) else { return nil }
        return APRSWeatherReport(
            timestamp: valid ? .monthDayHourMinute(month: month, day: day, hour: hour, minute: minute) : nil,
            weather: weather, comment: APRSText.decode(comment))
    }

    /// Liefert nil, wenn kein einziges Feld erkannt wird. `allowsWindPrefix`:
    /// hinter einer Position stehen Windrichtung und -geschwindigkeit als `DDD/SSS`.
    static func decodeFields(_ bytes: ArraySlice<UInt8>,
                             allowsWindPrefix: Bool) -> (APRSWeather, ArraySlice<UInt8>)? {
        var weather = APRSWeather()
        var rest = bytes
        var fieldCount = 0

        if allowsWindPrefix, rest.count >= 7,
           rest[rest.index(rest.startIndex, offsetBy: 3)] == UInt8(ascii: "/"),
           let direction = value(rest.prefix(3)), let speed = value(rest.dropFirst(4).prefix(3)) {
            weather.windDirectionDegrees = direction
            weather.windSpeedMph = speed
            rest = rest.dropFirst(7)
            fieldCount += 1
        }

        var hasWindSpeed = fieldCount > 0
        while let key = rest.first {
            // Das zweite `s` ist der Schneefall; er darf einen Dezimalpunkt tragen.
            if key == UInt8(ascii: "s"), hasWindSpeed {
                guard rest.count > 3, let snow = decimal(rest.dropFirst().prefix(3)) else { break }
                weather.snowLast24Hours = snow
                rest = rest.dropFirst(4)
            } else if key == UInt8(ascii: "#") {
                // Rohzähler des Regenmessers: überlesen.
                guard rest.count > 3, value(rest.dropFirst().prefix(3)) != nil else { break }
                rest = rest.dropFirst(4)
            } else {
                guard let field = field(for: key), rest.count > field.length,
                      let parsed = value(rest.dropFirst().prefix(field.length)) else { break }
                weather[keyPath: field.keyPath] = field.transform(parsed)
                rest = rest.dropFirst(1 + field.length)
                if key == UInt8(ascii: "s") { hasWindSpeed = true }
            }
            fieldCount += 1
        }
        return fieldCount > 0 ? (weather, rest) : nil
    }

    private struct Field {
        let length: Int
        let keyPath: WritableKeyPath<APRSWeather, Int?>
        var transform: (Int?) -> Int? = { $0 }
    }

    private static func field(for key: UInt8) -> Field? {
        switch key {
        case UInt8(ascii: "c"): return Field(length: 3, keyPath: \.windDirectionDegrees)
        case UInt8(ascii: "s"): return Field(length: 3, keyPath: \.windSpeedMph)
        case UInt8(ascii: "g"): return Field(length: 3, keyPath: \.gustMph)
        case UInt8(ascii: "t"): return Field(length: 3, keyPath: \.temperatureFahrenheit)
        case UInt8(ascii: "r"): return Field(length: 3, keyPath: \.rainLastHour)
        case UInt8(ascii: "p"): return Field(length: 3, keyPath: \.rainLast24Hours)
        case UInt8(ascii: "P"): return Field(length: 3, keyPath: \.rainSinceMidnight)
        // «00» steht für 100 %.
        case UInt8(ascii: "h"): return Field(length: 2, keyPath: \.humidityPercent,
                                             transform: { $0 == 0 ? 100 : $0 })
        case UInt8(ascii: "b"): return Field(length: 5, keyPath: \.pressureTenthsMillibar)
        case UInt8(ascii: "L"): return Field(length: 3, keyPath: \.luminosity)
        // Kleines «l»: Werte ab 1000 W/m², übertragen ohne die Tausenderstelle.
        case UInt8(ascii: "l"): return Field(length: 3, keyPath: \.luminosity,
                                             transform: { $0.map { $0 + 1000 } })
        default: return nil
        }
    }

    /// Ziffern (bei Temperaturen mit führendem Minus) oder Platzhalter.
    /// Äusseres nil: kein gültiges Wertfeld.
    private static func value(_ bytes: ArraySlice<UInt8>) -> Int?? {
        guard !bytes.isEmpty else { return nil }
        if bytes.allSatisfy({ $0 == UInt8(ascii: ".") }) || bytes.allSatisfy({ $0 == UInt8(ascii: " ") }) {
            return .some(nil)
        }
        let negative = bytes.first == UInt8(ascii: "-") && bytes.count > 1
        guard let magnitude = number(negative ? bytes.dropFirst() : bytes) else { return nil }
        return .some(negative ? -magnitude : magnitude)
    }

    /// Ziffern mit höchstens einem Dezimalpunkt; Platzhalter ergeben nil im Wert.
    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Double?? {
        if bytes.allSatisfy({ $0 == UInt8(ascii: ".") }) || bytes.allSatisfy({ $0 == UInt8(ascii: " ") }) {
            return .some(nil)
        }
        guard bytes.allSatisfy({ $0 == UInt8(ascii: ".") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              bytes.filter({ $0 == UInt8(ascii: ".") }).count <= 1,
              let parsed = Double(String(decoding: bytes, as: UTF8.self)) else { return nil }
        return .some(parsed)
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 9 else { return nil }
        var result = 0
        for byte in bytes {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            result = result * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return result
    }
}

/// Telemetrie, nur roh: Laufnummer, Analog- und Digitalwerte.
enum APRSTelemetryDecoder {
    private static let maxAnalog = 5
    private static let maxDigital = 8

    static func decode(_ payload: ArraySlice<UInt8>) -> APRSTelemetry? {
        guard payload.starts(with: Array("T#".utf8)) else { return nil }
        var body = Array(payload.dropFirst(2))
        // `T#MIC199,…`: nach der Kennung MIC darf das Komma fehlen.
        let mic = Array("MIC".utf8)
        if body.starts(with: mic), body.count > mic.count, body[mic.count] != UInt8(ascii: ",") {
            body.insert(UInt8(ascii: ","), at: mic.count)
        }
        let fields = body[...]
            .split(separator: UInt8(ascii: ","), maxSplits: maxAnalog + 1,
                   omittingEmptySubsequences: false)
        // Mindestens Laufnummer und ein Wert.
        guard fields.count >= 2, let sequenceBytes = fields.first,
              (1...5).contains(sequenceBytes.count),
              sequenceBytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }

        var analog: [Double?] = []
        var digital: [Bool] = []
        var comment: ArraySlice<UInt8> = []
        for (index, field) in fields.dropFirst().enumerated() {
            if index < maxAnalog {
                analog.append(Double(String(decoding: field, as: UTF8.self)).flatMap { $0.isFinite ? $0 : nil })
            } else {
                let bits = field.prefix(maxDigital).prefix { $0 == UInt8(ascii: "0") || $0 == UInt8(ascii: "1") }
                digital = bits.map { $0 == UInt8(ascii: "1") }
                comment = field.dropFirst(bits.count)
            }
        }
        guard analog.contains(where: { $0 != nil }) else { return nil }
        return APRSTelemetry(sequence: String(decoding: sequenceBytes, as: UTF8.self),
                             analog: analog, digital: digital, comment: APRSText.decode(comment))
    }
}
