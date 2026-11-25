import Foundation

/// Was ein APRS-IS-Client ausser den Paketen selbst braucht: Login-Zeile,
/// Serverfilter und die Kommentarzeilen des Servers. Kein Netzwerkcode.
public enum APRSIS {
    /// Passcode für reines Mitlesen («unverified»).
    public static let readOnlyPasscode = "-1"
    /// Filterport: der Server schickt nur, was der Filter verlangt.
    public static let filterPort: UInt16 = 14580

    /// `user CALL pass PASS vers NAME VERSION filter …`, ohne Zeilenende.
    /// nil, wenn das Rufzeichen leer ist oder unzulässige Zeichen enthält —
    /// der Server lehnt Platzhalter wie `N0CALL` ohnehin ab.
    public static func loginLine(callsign: String, passcode: String = readOnlyPasscode,
                                 software: String, version: String, filter: String) -> String? {
        let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard isValidLoginCallsign(call), isToken(passcode), isToken(software), isToken(version) else {
            return nil
        }
        var line = "user \(call) pass \(passcode) vers \(software) \(version)"
        let cleaned = sanitizedFilter(filter)
        if !cleaned.isEmpty { line += " filter \(cleaned)" }
        return line
    }

    /// Buchstaben, Ziffern und höchstens ein Bindestrich vor der SSID, 3–9 Zeichen.
    public static func isValidLoginCallsign(_ call: String) -> Bool {
        let bytes = Array(call.utf8)
        guard (3...9).contains(bytes.count), bytes.filter({ $0 == UInt8(ascii: "-") }).count <= 1,
              bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-") else { return false }
        return bytes.allSatisfy {
            $0 == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        }
    }

    /// Umkreisfilter `r/Breite/Länge/km`. Zwei Nachkommastellen (rund 1 km)
    /// genügen für einen Umkreis und geben den Standort nicht genauer preis.
    public static func rangeFilter(latitude: Double, longitude: Double, kilometres: Int) -> String? {
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude),
              kilometres > 0 else { return nil }
        return String(format: "r/%.2f/%.2f/%d", locale: Locale(identifier: "en_US_POSIX"),
                      latitude, longitude, kilometres)
    }

    /// Frei eingegebener Filter: nur druckbares ASCII, Leerraum zusammengezogen —
    /// ein Zeilenumbruch darf nie eine zweite Zeile an den Server schicken.
    public static func sanitizedFilter(_ filter: String) -> String {
        filter.unicodeScalars
            .map { $0.value > 0x20 && $0.value < 0x7F ? Character($0) : " " }
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }
            .joined(separator: " ")
    }

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }
}

/// Eine Zeile vom Server, die kein Paket ist (beginnt mit `#`).
public enum APRSISServerLine: Equatable, Sendable {
    /// `# logresp CALL verified|unverified, server NAME`
    case loginResponse(callsign: String, isVerified: Bool, server: String?)
    /// Der Server lässt das Rufzeichen nicht zu (beobachtet bei aprsc:
    /// `# Login by user not allowed`); die Verbindung endet danach.
    case loginRejected(String)
    /// Banner und Lebenszeichen.
    case comment(String)

    /// nil, wenn die Zeile nicht mit `#` beginnt.
    public init?(_ bytes: [UInt8]) {
        guard bytes.first == UInt8(ascii: "#") else { return nil }
        let text = (String(bytes: bytes.dropFirst(), encoding: .utf8)
                    ?? String(bytes: bytes.dropFirst(), encoding: .isoLatin1) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ").map(String.init)
        if words.count >= 3, words[0] == "logresp" {
            let state = words[2].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if state == "verified" || state == "unverified" {
                var server: String?
                if let index = words.firstIndex(of: "server"), index + 1 < words.count {
                    server = words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ","))
                }
                self = .loginResponse(callsign: words[1], isVerified: state == "verified", server: server)
                return
            }
        }
        let lowered = text.lowercased()
        if lowered.contains("login") && lowered.contains("not allowed") {
            self = .loginRejected(text)
        } else {
            self = .comment(text)
        }
    }
}

/// Zerlegt den Bytestrom in Zeilen. Bleibt ein Zeilenende aus, wächst der
/// Puffer nicht unbegrenzt: eine überlange Zeile wird bis zum nächsten
/// Zeilenende verworfen und gezählt.
public struct APRSISLineSplitter: Sendable {
    public let maxLineBytes: Int
    public private(set) var discardedLines = 0
    private var buffer: [UInt8] = []
    private var isDiscarding = false

    public init(maxLineBytes: Int = APRSParser.maxLineBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Liefert alle vollständigen, nicht leeren Zeilen ohne `\r\n`.
    public mutating func append<S: Sequence>(_ bytes: S) -> [[UInt8]] where S.Element == UInt8 {
        var lines: [[UInt8]] = []
        for byte in bytes {
            if byte == 0x0A {
                if isDiscarding {
                    isDiscarding = false
                } else {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    if !buffer.isEmpty { lines.append(buffer) }
                }
                buffer.removeAll(keepingCapacity: true)
            } else if !isDiscarding {
                buffer.append(byte)
                // Ein abschliessendes `\r` zählt nicht zur Zeilenlänge.
                if buffer.count > maxLineBytes + 1 {
                    buffer.removeAll(keepingCapacity: true)
                    isDiscarding = true
                    discardedLines += 1
                }
            }
        }
        return lines
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        isDiscarding = false
    }
}

/// Wartezeiten zwischen Verbindungsversuchen: verdoppelt bis zur Obergrenze,
/// damit ein Ausfall keinen Verbindungssturm auf die Server auslöst.
public struct APRSISBackoff: Equatable, Sendable {
    public let initial: TimeInterval
    public let maximum: TimeInterval
    public private(set) var attempts = 0

    public init(initial: TimeInterval = 5, maximum: TimeInterval = 300) {
        self.initial = max(1, initial)
        self.maximum = max(self.initial, maximum)
    }

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(maximum, initial * pow(2, Double(min(attempts, 20))))
        attempts += 1
        return delay
    }

    /// Nach einem bestätigten Login.
    public mutating func reset() { attempts = 0 }
}
