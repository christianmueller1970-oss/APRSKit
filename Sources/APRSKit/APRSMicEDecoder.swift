import Foundation

/// Mic-E (`` ` `` aktuell, `'` alt): Breitengrad, Message-Bits, Hemisphären
/// und Längengrad-Versatz stecken in den sechs Zeichen der Zieladresse, der
/// Rest binär in den Nutzdaten.
///
/// Umsetzung nach dem Verfahren gängiger Parser (Ham::APRS::FAP); gegen ein
/// reales Paket getestet, die Tabelle der Zielzeichen noch gegen APRS101
/// Kapitel 10 zu verifizieren (siehe Plan).
enum APRSMicEDecoder {
    private static let destinationLength = 6
    private static let informationLength = 8

    private struct DestinationCharacter {
        /// Ziffer des Breitengrads; nil = Leerzeichen (Unschärfe).
        let digit: UInt8?
        /// 0, 1 = Standard, 2 = Custom.
        let messageBit: Int
        /// Zeichen aus `P…Z`: Nord, Versatz +100, West (je nach Stelle).
        let isUpperRange: Bool
    }

    static func decode(_ payload: ArraySlice<UInt8>, destination: ArraySlice<UInt8>) -> APRSPositionReport? {
        // Die SSID der Zieladresse gehört nicht zur Kodierung.
        let call = Array(destination.prefix { $0 != UInt8(ascii: "-") })
        let info = Array(payload.dropFirst())
        guard call.count == destinationLength, info.count >= informationLength else { return nil }

        var characters: [DestinationCharacter] = []
        for (index, byte) in call.enumerated() {
            guard let character = destinationCharacter(byte, allowsCustom: index < 3) else { return nil }
            characters.append(character)
        }

        // Breitengrad als `DDMM.mmH` zusammensetzen und wie eine
        // unkomprimierte Position auswerten (inkl. Unschärfe).
        let space = UInt8(ascii: " ")
        let d = characters.map { $0.digit ?? space }
        let latitudeField = [d[0], d[1], d[2], d[3], UInt8(ascii: "."), d[4], d[5],
                             characters[3].isUpperRange ? UInt8(ascii: "N") : UInt8(ascii: "S")]
        guard let (latitude, ambiguity) = APRSPositionDecoder.decodeLatitude(latitudeField) else { return nil }

        // Zulässige Wertebereiche der sechs Bytes und des Symbols.
        guard (0x26...0x7F).contains(info[0]), (0x26...0x61).contains(info[1]),
              (0x1C...0x7F).contains(info[2]), (0x1C...0x7F).contains(info[3]),
              (0x1C...0x7D).contains(info[4]), (0x1C...0x7F).contains(info[5]),
              (0x21...0x7B).contains(info[6]) || info[6] == 0x7D,
              isSymbolTable(info[7]) else { return nil }

        var degrees = Int(info[0]) - 28
        if characters[4].isUpperRange { degrees += 100 }
        if (180...189).contains(degrees) { degrees -= 80 } else if (190...199).contains(degrees) { degrees -= 190 }
        var minutes = Int(info[1]) - 28
        if minutes >= 60 { minutes -= 60 }
        let hundredths = Int(info[2]) - 28
        guard (0...179).contains(degrees), (0...59).contains(minutes), (0...99).contains(hundredths) else {
            return nil
        }
        let longitudeText = String(format: "%03d%02d.%02d", degrees, minutes, hundredths)
            + (characters[5].isUpperRange ? "W" : "E")
        guard let longitude = APRSPositionDecoder.decodeLongitude(Array(longitudeText.utf8),
                                                                  ambiguity: ambiguity) else { return nil }

        // Geschwindigkeit (Knoten) und Kurs teilen sich drei Bytes.
        let speedCourse = Int(info[4]) - 28
        var speed = (Int(info[3]) - 28) * 10 + speedCourse / 10
        var course = (speedCourse % 10) * 100 + (Int(info[5]) - 28)
        if speed >= 800 { speed -= 800 }
        if course >= 400 { course -= 400 }

        var body = APRSPositionDecoder.Body(latitude: latitude, longitude: longitude,
                                            symbolTable: info[7], symbolCode: info[6],
                                            rest: info[informationLength...])
        body.ambiguity = ambiguity
        body.course = (1...360).contains(course) ? course : nil
        body.speedKnots = Double(speed)
        body.micEStatus = status(characters)
        applyAltitude(to: &body)
        return APRSPositionDecoder.report(body, timestamp: nil, supportsMessaging: false)
    }

    /// Stellen 1–3 dürfen `A…K` (Custom-Bit) enthalten, Stellen 4–6 nicht.
    private static func destinationCharacter(_ byte: UInt8, allowsCustom: Bool) -> DestinationCharacter? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return DestinationCharacter(digit: byte, messageBit: 0, isUpperRange: false)
        case UInt8(ascii: "L"):
            return DestinationCharacter(digit: nil, messageBit: 0, isUpperRange: false)
        case UInt8(ascii: "P")...UInt8(ascii: "Y"):
            return DestinationCharacter(digit: byte - UInt8(ascii: "P") + UInt8(ascii: "0"),
                                        messageBit: 1, isUpperRange: true)
        case UInt8(ascii: "Z"):
            return DestinationCharacter(digit: nil, messageBit: 1, isUpperRange: true)
        case UInt8(ascii: "A")...UInt8(ascii: "J") where allowsCustom:
            return DestinationCharacter(digit: byte - UInt8(ascii: "A") + UInt8(ascii: "0"),
                                        messageBit: 2, isUpperRange: false)
        case UInt8(ascii: "K") where allowsCustom:
            return DestinationCharacter(digit: nil, messageBit: 2, isUpperRange: false)
        default:
            return nil
        }
    }

    /// Bits A, B, C aus den ersten drei Zeichen: 111 = M0 … 001 = M6, 000 = Notfall.
    /// Standard- und Custom-Zeichen gemischt ergibt keine gültige Meldung.
    private static func status(_ characters: [DestinationCharacter]) -> APRSMicEStatus? {
        let bits = characters.prefix(3).map(\.messageBit)
        let value = bits.reduce(0) { $0 << 1 | ($1 == 0 ? 0 : 1) }
        if value == 0 { return .emergency }
        let usesStandard = bits.contains(1), usesCustom = bits.contains(2)
        if usesStandard && usesCustom { return nil }
        return usesCustom ? .custom(7 - value) : .standard(7 - value)
    }

    /// Höhe als drei Base91-Zeichen vor `}`: Meter über Meer plus 10 000.
    private static func applyAltitude(to body: inout APRSPositionDecoder.Body) {
        let bytes = Array(body.rest)
        guard bytes.count >= 4 else { return }
        for end in 3..<bytes.count where bytes[end] == UInt8(ascii: "}") {
            let digits = bytes[(end - 3)..<end]
            guard digits.allSatisfy({ (0x21...0x7B).contains($0) }) else { continue }
            let value = digits.reduce(0) { $0 * 91 + Int($1) - 33 }
            body.altitudeFeet = Double(value - 10_000) / 0.3048
            body.rest = (bytes[..<(end - 3)] + bytes[(end + 1)...])[...]
            return
        }
    }

    private static func isSymbolTable(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "/") || byte == UInt8(ascii: "\\")
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
