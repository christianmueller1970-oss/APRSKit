import Foundation

/// Positionsmeldungen: unkomprimiert (`DDMM.mmN` Tabelle `DDDMM.mmW` Symbol)
/// und komprimiert (Base91). Jeder Zugriff ist gegen die Länge der Nutzdaten
/// geprüft.
enum APRSPositionDecoder {
    private static let latitudeLength = 8
    private static let longitudeLength = 9
    private static let timestampLength = 7
    /// Tabelle, 4 + 4 Zeichen Breite/Länge, Symbolcode, 2 Zeichen cs, Typ-Byte.
    private static let compressedLength = 13

    /// Position samt Symbol, wie sie auch in Objekten und Items steht.
    struct Body {
        var latitude: Double
        var longitude: Double
        var ambiguity = 0
        var symbolTable: UInt8
        var symbolCode: UInt8
        var course: Int?
        var speedKnots: Double?
        var altitudeFeet: Double?
        var radioRangeMiles: Double?
        var phg: APRSPHG?
        var micEStatus: APRSMicEStatus?
        var weather: APRSWeather?
        /// Was nach Position und Datenerweiterungen folgt.
        var rest: ArraySlice<UInt8>
    }

    static func decode(_ payload: ArraySlice<UInt8>) -> APRSPositionReport? {
        guard let type = payload.first else { return nil }
        var rest = payload.dropFirst()

        let hasTimestamp = type == UInt8(ascii: "/") || type == UInt8(ascii: "@")
        let supportsMessaging = type == UInt8(ascii: "=") || type == UInt8(ascii: "@")

        var timestamp: APRSTimestamp?
        if hasTimestamp {
            guard rest.count >= timestampLength else { return nil }
            timestamp = decodeTimestamp(rest.prefix(timestampLength))
            rest = rest.dropFirst(timestampLength)
        }

        guard let body = decodeBody(rest) else { return nil }
        return report(body, timestamp: timestamp, supportsMessaging: supportsMessaging)
    }

    static func report(_ body: Body, timestamp: APRSTimestamp?,
                       supportsMessaging: Bool) -> APRSPositionReport {
        APRSPositionReport(
            latitude: body.latitude, longitude: body.longitude, ambiguity: body.ambiguity,
            symbolTable: Character(UnicodeScalar(body.symbolTable)),
            symbolCode: Character(UnicodeScalar(body.symbolCode)),
            timestamp: timestamp, supportsMessaging: supportsMessaging,
            course: body.course, speedKnots: body.speedKnots,
            altitudeFeet: body.altitudeFeet, radioRangeMiles: body.radioRangeMiles,
            phg: body.phg, micEStatus: body.micEStatus, weather: body.weather,
            comment: APRSText.decode(body.rest))
    }

    /// Unkomprimierte Positionen beginnen mit einer Ziffer, komprimierte mit
    /// dem Tabellenzeichen.
    static func decodeBody(_ bytes: ArraySlice<UInt8>) -> Body? {
        guard let first = bytes.first,
              var body = digit(first) != nil ? decodeUncompressed(bytes) : decodeCompressed(bytes)
        else { return nil }
        APRSDataExtension.apply(to: &body)
        if body.symbolCode == UInt8(ascii: "_"),
           let (parsed, rest) = APRSWeatherDecoder.decodeFields(body.rest, allowsWindPrefix: true) {
            var weather = parsed
            // Komprimierte Wetterberichte tragen den Wind in den cs-Bytes
            // (Richtung in Grad, Geschwindigkeit in Knoten → mph).
            if let direction = body.course, let knots = body.speedKnots {
                weather.windDirectionDegrees = weather.windDirectionDegrees ?? direction
                weather.windSpeedMph = weather.windSpeedMph ?? Int((knots * 1.15078).rounded())
                body.course = nil
                body.speedKnots = nil
            }
            body.weather = weather
            body.rest = rest
        }
        return body
    }

    private static func decodeUncompressed(_ bytes: ArraySlice<UInt8>) -> Body? {
        var rest = bytes
        guard rest.count >= latitudeLength + 1 + longitudeLength + 1 else { return nil }
        let latitudeField = Array(rest.prefix(latitudeLength))
        rest = rest.dropFirst(latitudeLength)
        let table = rest[rest.startIndex]
        rest = rest.dropFirst()
        let longitudeField = Array(rest.prefix(longitudeLength))
        rest = rest.dropFirst(longitudeLength)
        let code = rest[rest.startIndex]
        rest = rest.dropFirst()

        guard let (latitude, ambiguity) = decodeLatitude(latitudeField),
              let longitude = decodeLongitude(longitudeField, ambiguity: ambiguity),
              isPrintable(table), isPrintable(code) else { return nil }
        return Body(latitude: latitude, longitude: longitude, ambiguity: ambiguity,
                    symbolTable: table, symbolCode: code, rest: rest)
    }

    // MARK: - Komprimiert

    /// `T YYYY XXXX S cs t`: Breite und Länge als vierstellige Base91-Zahlen,
    /// danach Kurs/Geschwindigkeit, Reichweite oder Höhe in `cs`.
    private static func decodeCompressed(_ bytes: ArraySlice<UInt8>) -> Body? {
        guard bytes.count >= compressedLength else { return nil }
        let f = Array(bytes.prefix(compressedLength))

        // Tabelle: `/`, `\`, Overlay A–Z; die Overlay-Ziffern 0–9 stehen als a–j.
        var table = f[0]
        switch table {
        case UInt8(ascii: "/"), UInt8(ascii: "\\"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            break
        case UInt8(ascii: "a")...UInt8(ascii: "j"):
            table = table - UInt8(ascii: "a") + UInt8(ascii: "0")
        default:
            return nil
        }
        guard let y = base91(f, 1..<5), let x = base91(f, 5..<9), isPrintable(f[9]) else { return nil }
        let latitude = 90 - Double(y) / 380_926
        let longitude = -180 + Double(x) / 190_463
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else { return nil }

        var body = Body(latitude: latitude, longitude: longitude, symbolTable: table,
                        symbolCode: f[9], rest: bytes.dropFirst(compressedLength))

        // Ein Leerzeichen an erster Stelle heisst: keine cs-Daten.
        let c = f[10], s = f[11], type = f[12]
        guard c != UInt8(ascii: " "), let sValue = base91Digit(s), let typeValue = base91Digit(type) else {
            return body
        }
        if typeValue & 0x18 == 0x10, let cValue = base91Digit(c) {
            // Positionsquelle GGA: cs ist die Höhe, 1.002^cs Fuss.
            body.altitudeFeet = pow(1.002, Double(cValue * 91 + sValue))
        } else if c == UInt8(ascii: "{") {
            body.radioRangeMiles = 2 * pow(1.08, Double(sValue))
        } else if let cValue = base91Digit(c), cValue < 90 {
            // Kurs in 4°-Schritten; 0 wird wie bei gängigen Parsern als Nord (360) geführt.
            body.course = cValue == 0 ? 360 : cValue * 4
            body.speedKnots = pow(1.08, Double(sValue)) - 1
        }
        return body
    }

    private static func base91Digit(_ byte: UInt8) -> Int? {
        (UInt8(ascii: "!")...UInt8(ascii: "{")).contains(byte) ? Int(byte) - 33 : nil
    }

    private static func base91(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.upperBound <= bytes.count else { return nil }
        var value = 0
        for index in range {
            guard let d = base91Digit(bytes[index]) else { return nil }
            value = value * 91 + d
        }
        return value
    }

    // MARK: - Zeitstempel

    static func decodeTimestamp(_ field: ArraySlice<UInt8>) -> APRSTimestamp? {
        let bytes = Array(field)
        guard bytes.count == timestampLength,
              let a = twoDigits(bytes, at: 0), let b = twoDigits(bytes, at: 2),
              let c = twoDigits(bytes, at: 4) else { return nil }
        switch bytes[6] {
        case UInt8(ascii: "z"), UInt8(ascii: "/"):
            guard (1...31).contains(a), b < 24, c < 60 else { return nil }
            return .dayHourMinute(day: a, hour: b, minute: c, isUTC: bytes[6] == UInt8(ascii: "z"))
        case UInt8(ascii: "h"):
            guard a < 24, b < 60, c < 60 else { return nil }
            return .hourMinuteSecond(hour: a, minute: b, second: c)
        default:
            return nil
        }
    }

    // MARK: - Koordinaten

    /// `DDMM.mmH`. Unschärfe: Minutenstellen von rechts durch Leerzeichen
    /// ersetzt. Der Wert ist dann die Mitte des Felds (wie gängige Parser,
    /// z. B. Ham::APRS::FAP; noch gegen APRS101 zu verifizieren).
    static func decodeLatitude(_ f: [UInt8]) -> (Double, Int)? {
        guard f.count == latitudeLength, f[4] == UInt8(ascii: ".") else { return nil }
        let sign: Double
        switch f[7] {
        case UInt8(ascii: "N"), UInt8(ascii: "n"): sign = 1
        case UInt8(ascii: "S"), UInt8(ascii: "s"): sign = -1
        default: return nil
        }
        // Minutenstellen von rechts nach links: Hundertstel, Zehntel, Einer, Zehner.
        let minuteDigits = [f[6], f[5], f[3], f[2]]
        var ambiguity = 0
        while ambiguity < 4, minuteDigits[ambiguity] == UInt8(ascii: " ") { ambiguity += 1 }
        guard let degrees = number(f, 0..<2),
              let minutes = minutes(tens: f[2], ones: f[3], tenths: f[5], hundredths: f[6],
                                    ambiguity: ambiguity) else { return nil }
        let value = Double(degrees) + minutes / 60
        guard value <= 90 else { return nil }
        return (sign * value, ambiguity)
    }

    /// `DDDMM.mmH`. Die Unschärfe gibt der Breitengrad vor; an den unscharfen
    /// Stellen ist der Inhalt des Längengrads ohne Bedeutung.
    static func decodeLongitude(_ f: [UInt8], ambiguity: Int) -> Double? {
        guard f.count == longitudeLength, f[5] == UInt8(ascii: ".") else { return nil }
        let sign: Double
        switch f[8] {
        case UInt8(ascii: "E"), UInt8(ascii: "e"): sign = 1
        case UInt8(ascii: "W"), UInt8(ascii: "w"): sign = -1
        default: return nil
        }
        guard let degrees = number(f, 0..<3),
              let minutes = minutes(tens: f[3], ones: f[4], tenths: f[6], hundredths: f[7],
                                    ambiguity: ambiguity) else { return nil }
        let value = Double(degrees) + minutes / 60
        guard value <= 180 else { return nil }
        return sign * value
    }

    /// Minuten mit Feldmitte je Unschärfe: 0 → MM.mm, 1 → MM.m5, 2 → MM.5,
    /// 3 → M5, 4 → 30.
    private static func minutes(tens: UInt8, ones: UInt8, tenths: UInt8, hundredths: UInt8,
                                ambiguity: Int) -> Double? {
        var value = 0.0
        switch ambiguity {
        case 0:
            guard let t = digit(tens), let o = digit(ones),
                  let z = digit(tenths), let h = digit(hundredths) else { return nil }
            value = Double(t * 10 + o) + Double(z) / 10 + Double(h) / 100
        case 1:
            guard let t = digit(tens), let o = digit(ones), let z = digit(tenths) else { return nil }
            value = Double(t * 10 + o) + Double(z) / 10 + 0.05
        case 2:
            guard let t = digit(tens), let o = digit(ones) else { return nil }
            value = Double(t * 10 + o) + 0.5
        case 3:
            guard let t = digit(tens) else { return nil }
            value = Double(t * 10) + 5
        default:
            value = 30
        }
        return value < 60 ? value : nil
    }

    // MARK: - Hilfen

    private static func digit(_ byte: UInt8) -> Int? {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ? Int(byte - UInt8(ascii: "0")) : nil
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.upperBound <= bytes.count else { return nil }
        var value = 0
        for index in range {
            guard let d = digit(bytes[index]) else { return nil }
            value = value * 10 + d
        }
        return value
    }

    private static func twoDigits(_ bytes: [UInt8], at index: Int) -> Int? {
        number(bytes, index..<(index + 2))
    }

    private static func isPrintable(_ byte: UInt8) -> Bool { byte > 0x20 && byte < 0x7F }
}
