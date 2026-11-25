import Foundation

extension APRSIS {
    /// Zieladresse eigener Pakete. `APZ…` ist der Bereich für experimentelle
    /// Software; eine eigene Kennung folgt nach Zuteilung (siehe Plan).
    public static let tocall = "APZHMT"

    /// Passcode zum Senden über APRS-IS, berechnet aus dem Rufzeichen ohne
    /// SSID in Grossbuchstaben. nil bei leerem oder nicht-ASCII-Rufzeichen.
    public static func passcode(for callsign: String) -> Int? {
        let base = callsign.trimmingCharacters(in: .whitespaces).uppercased()
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let bytes = Array(base.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        var hash = 0x73E2
        var index = 0
        while index < bytes.count {
            hash ^= Int(bytes[index]) << 8
            if index + 1 < bytes.count { hash ^= Int(bytes[index + 1]) }
            index += 2
        }
        return hash & 0x7FFF
    }
}

/// Erzeugt eigene Pakete im TNC2-Textformat. Jede Funktion liefert nil, wenn
/// die Eingaben kein gültiges Paket ergeben — gesendet wird dann nichts.
public enum APRSEncoder {
    /// Messages: höchstens 67 Zeichen Text, Laufnummer 1–5 Zeichen.
    public static let maxMessageLength = 67
    /// Kommentar hinter einer Position.
    public static let maxCommentLength = 43
    public static let objectNameLength = 9

    /// Ganze Zeile für APRS-IS: `QUELLE>APZHMT,TCPIP*:Nutzdaten`.
    public static func line(source: String, payload: String) -> String? {
        let call = source.trimmingCharacters(in: .whitespaces).uppercased()
        guard APRSIS.isValidLoginCallsign(call), !payload.isEmpty, isPrintable(payload) else { return nil }
        return "\(call)>\(APRSIS.tocall),TCPIP*:\(payload)"
    }

    // MARK: - Position

    /// Unkomprimierte Position ohne Zeitstempel. `ambiguity` 0…4 ersetzt
    /// Minutenstellen von rechts durch Leerzeichen.
    public static func position(latitude: Double, longitude: Double, ambiguity: Int = 0,
                                symbolTable: Character, symbolCode: Character,
                                supportsMessaging: Bool = true, altitudeFeet: Int? = nil,
                                comment: String = "") -> String? {
        guard let body = positionBody(latitude: latitude, longitude: longitude, ambiguity: ambiguity,
                                      symbolTable: symbolTable, symbolCode: symbolCode) else { return nil }
        var text = (supportsMessaging ? "=" : "!") + body
        if let altitude = altitudeFeet, (-99_999...999_999).contains(altitude) {
            text += altitude < 0 ? String(format: "/A=-%05d", -altitude) : String(format: "/A=%06d", altitude)
        }
        return text + sanitized(comment, maxLength: maxCommentLength)
    }

    /// Objekt: `;NAME_____*DDHHMMz` plus Position. `isLive == false` löscht es.
    public static func object(name: String, isLive: Bool, time: Date,
                              latitude: Double, longitude: Double,
                              symbolTable: Character, symbolCode: Character,
                              comment: String = "") -> String? {
        let cleaned = sanitized(name, maxLength: objectNameLength).trimmingCharacters(in: .whitespaces)
        guard (3...objectNameLength).contains(cleaned.count),
              let body = positionBody(latitude: latitude, longitude: longitude, ambiguity: 0,
                                      symbolTable: symbolTable, symbolCode: symbolCode) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.day, .hour, .minute], from: time)
        let stamp = String(format: "%02d%02d%02dz", parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0)
        let padded = cleaned.padding(toLength: objectNameLength, withPad: " ", startingAt: 0)
        return ";" + padded + (isLive ? "*" : "_") + stamp + body
            + sanitized(comment, maxLength: maxCommentLength)
    }

    private static func positionBody(latitude: Double, longitude: Double, ambiguity: Int,
                                     symbolTable: Character, symbolCode: Character) -> String? {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude),
              (0...4).contains(ambiguity),
              APRSSymbol.isValidTable(symbolTable), APRSSymbol.isValidCode(symbolCode) else { return nil }
        let lat = coordinate(abs(latitude), degreeDigits: 2, maxDegrees: 90)
        let lon = coordinate(abs(longitude), degreeDigits: 3, maxDegrees: 180)
        return blur(lat, ambiguity) + (latitude >= 0 ? "N" : "S") + String(symbolTable)
            + blur(lon, ambiguity) + (longitude >= 0 ? "E" : "W") + String(symbolCode)
    }

    /// `DDMM.mm` bzw. `DDDMM.mm`; Rundung auf Hundertstelminuten mit Übertrag.
    private static func coordinate(_ value: Double, degreeDigits: Int, maxDegrees: Int) -> String {
        var hundredths = Int((value * 6000).rounded())      // Hundertstel Bogenminuten
        hundredths = min(hundredths, maxDegrees * 6000)
        let degrees = hundredths / 6000, rest = hundredths % 6000
        return String(format: "%0\(degreeDigits)d%02d.%02d", degrees, rest / 100, rest % 100)
    }

    /// Ersetzt die letzten `ambiguity` Minutenziffern durch Leerzeichen.
    private static func blur(_ field: String, _ ambiguity: Int) -> String {
        var characters = Array(field)
        var remaining = ambiguity
        var index = characters.count - 1
        while remaining > 0, index >= 0 {
            if characters[index] != "." {
                characters[index] = " "
                remaining -= 1
            }
            index -= 1
        }
        return String(characters)
    }

    // MARK: - Messages

    /// `:ADRESSAT :Text{Nr`. `messageID == nil` sendet ohne Bestätigungswunsch.
    public static func message(to addressee: String, text: String, messageID: String?) -> String? {
        guard let address = addresseeField(addressee) else { return nil }
        let body = messageText(text)
        guard !body.isEmpty, body.count <= maxMessageLength else { return nil }
        guard let messageID else { return ":\(address):\(body)" }
        guard isMessageID(messageID) else { return nil }
        return ":\(address):\(body){\(messageID)"
    }

    /// Bestätigung für eine empfangene Message.
    public static func ack(to addressee: String, messageID: String) -> String? {
        guard let address = addresseeField(addressee), isMessageID(messageID) else { return nil }
        return ":\(address):ack\(messageID)"
    }

    /// Text, wie er gesendet würde: druckbares ASCII, ohne die im
    /// Nachrichtentext reservierten Zeichen `{`, `|` und `~`.
    public static func messageText(_ text: String) -> String {
        sanitized(text, maxLength: Int.max, forbidden: ["{", "|", "~"])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func addresseeField(_ addressee: String) -> String? {
        let cleaned = addressee.trimmingCharacters(in: .whitespaces).uppercased()
        guard (1...9).contains(cleaned.count),
              cleaned.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != ":" }) else {
            return nil
        }
        return cleaned.padding(toLength: 9, withPad: " ", startingAt: 0)
    }

    private static func isMessageID(_ id: String) -> Bool {
        (1...5).contains(id.count) && id.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
    }

    // MARK: - Hilfen

    /// Nur druckbares ASCII; alles andere (Umlaute, Zeilenumbrüche) wird zu `?`
    /// bzw. Leerzeichen, damit nie eine zweite Zeile entsteht.
    private static func sanitized(_ text: String, maxLength: Int, forbidden: Set<Character> = []) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if result.count >= maxLength { break }
            let character = Character(scalar)
            if scalar.value < 0x20 || scalar.value == 0x7F {
                result.append(" ")
            } else if scalar.value > 0x7F || forbidden.contains(character) {
                result.append("?")
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func isPrintable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }
}

extension APRSSymbol {
    /// Tabellenzeichen für eigene Pakete: `/`, `\` oder Overlay 0–9 / A–Z.
    public static func isValidTable(_ table: Character) -> Bool {
        guard let value = table.asciiValue else { return false }
        return value == UInt8(ascii: "/") || value == UInt8(ascii: "\\")
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(value)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(value)
    }

    public static func isValidCode(_ code: Character) -> Bool {
        guard let value = code.asciiValue else { return false }
        return (33...126).contains(value)
    }
}
