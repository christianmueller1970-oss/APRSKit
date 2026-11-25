import Foundation

/// Sendeleistung, Antennenhöhe und Gewinn aus der Erweiterung `PHGphgd`.
public struct APRSPHG: Equatable, Sendable {
    public let powerWatts: Int
    /// Antennenhöhe über dem mittleren Gelände in Fuss.
    public let heightFeet: Int
    public let gainDb: Int
    /// Hauptstrahlrichtung in Grad (45°-Schritte); nil = Rundstrahler.
    public let directivityDegrees: Int?

    public init(powerWatts: Int, heightFeet: Int, gainDb: Int, directivityDegrees: Int?) {
        self.powerWatts = powerWatts
        self.heightFeet = heightFeet
        self.gainDb = gainDb
        self.directivityDegrees = directivityDegrees
    }
}

/// Datenerweiterungen hinter einer Position: sieben Bytes direkt nach dem
/// Symbolcode (`CSE/SPD`, `PHG`, `RNG`) und die Höhe `/A=` irgendwo im Kommentar.
enum APRSDataExtension {
    private static let length = 7

    static func apply(to body: inout APRSPositionDecoder.Body) {
        // Bei Wettersymbol `_` sind die ersten sieben Bytes Windrichtung und
        // -geschwindigkeit; die wertet der Wetter-Decoder aus.
        if body.symbolCode != UInt8(ascii: "_") {
            applyLeading(to: &body)
        }
        applyAltitude(to: &body)
    }

    private static func applyLeading(to body: inout APRSPositionDecoder.Body) {
        guard body.rest.count >= length else { return }
        let f = Array(body.rest.prefix(length))

        if f[3] == UInt8(ascii: "/"),
           let course = courseOrSpeed(f, 0..<3), let speed = courseOrSpeed(f, 4..<7) {
            // Kurs 000 und Platzhalter (`...`, Leerzeichen) heissen «unbekannt».
            if let value = course, (1...360).contains(value), body.course == nil {
                body.course = value
            }
            if let value = speed, body.speedKnots == nil {
                body.speedKnots = Double(value)
            }
            body.rest = body.rest.dropFirst(length)
        } else if hasPrefix(f, "PHG"),
                  let p = digit(f[3]), let d = digit(f[6]), d <= 8,
                  f[4] >= UInt8(ascii: "0"), f[4] < 0x7F, let g = digit(f[5]) {
            // Die Höhenstelle darf über `9` hinauslaufen (ASCII-Folge), deshalb
            // Abstand zu `0` statt Ziffernprüfung.
            let exponent = Int(f[4] - UInt8(ascii: "0"))
            body.phg = APRSPHG(powerWatts: p * p,
                               heightFeet: exponent < 40 ? 10 << exponent : Int.max,
                               gainDb: g,
                               directivityDegrees: d == 0 ? nil : d * 45)
            body.rest = body.rest.dropFirst(length)
            // Variante aus APRS 1.2: ein Zeichen «Baken pro Stunde» und ein
            // Pflicht-Schrägstrich hinter den sieben Bytes (`PHG72604/`).
            let extra = Array(body.rest.prefix(2))
            if extra.count == 2, extra[1] == UInt8(ascii: "/"),
               digit(extra[0]) != nil || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(extra[0]) {
                body.rest = body.rest.dropFirst(2)
            }
        } else if hasPrefix(f, "RNG"), let miles = number(f, 3..<7) {
            if body.radioRangeMiles == nil { body.radioRangeMiles = Double(miles) }
            body.rest = body.rest.dropFirst(length)
        }
    }

    /// `/A=dddddd` in Fuss; die erste Stelle darf ein Minus sein.
    private static func applyAltitude(to body: inout APRSPositionDecoder.Body) {
        let bytes = Array(body.rest)
        let marker = Array("/A=".utf8)
        let total = marker.count + 6
        guard bytes.count >= total else { return }
        for start in 0...(bytes.count - total) where Array(bytes[start..<(start + 3)]) == marker {
            let digits = Array(bytes[(start + 3)..<(start + total)])
            let negative = digits[0] == UInt8(ascii: "-")
            guard let value = number(digits, (negative ? 1 : 0)..<6) else { continue }
            if body.altitudeFeet == nil { body.altitudeFeet = Double(negative ? -value : value) }
            body.rest = (bytes[..<start] + bytes[(start + total)...])[...]
            return
        }
    }

    // MARK: - Hilfen

    /// Drei Ziffern, oder drei Punkte bzw. Leerzeichen für «unbekannt».
    /// Äusseres nil: das Feld hat keine der beiden Formen.
    private static func courseOrSpeed(_ f: [UInt8], _ range: Range<Int>) -> Int?? {
        if let value = number(f, range) { return .some(value) }
        let field = f[range]
        if field.allSatisfy({ $0 == UInt8(ascii: ".") }) || field.allSatisfy({ $0 == UInt8(ascii: " ") }) {
            return .some(nil)
        }
        return nil
    }

    private static func hasPrefix(_ f: [UInt8], _ prefix: String) -> Bool {
        f.starts(with: Array(prefix.utf8))
    }

    private static func digit(_ byte: UInt8) -> Int? {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ? Int(byte - UInt8(ascii: "0")) : nil
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.upperBound <= bytes.count, !range.isEmpty else { return nil }
        var value = 0
        for index in range {
            guard let d = digit(bytes[index]) else { return nil }
            value = value * 10 + d
        }
        return value
    }
}
