import Foundation

/// Wo ein APRS-Symbol in den Symbolblättern liegt. Blatt 0 = primäre Tabelle
/// (`/`), Blatt 1 = alternative Tabelle (`\`), Blatt 2 = Overlay-Zeichen.
/// Die Zelle ist der ASCII-Code minus 33 (16 Spalten je Zeile).
public struct APRSSymbolSprite: Equatable, Sendable {
    public let sheet: Int
    public let index: Int
    /// Zelle des Overlay-Zeichens in Blatt 2; nil ohne Overlay.
    public let overlayIndex: Int?

    public init(sheet: Int, index: Int, overlayIndex: Int? = nil) {
        self.sheet = sheet
        self.index = index
        self.overlayIndex = overlayIndex
    }
}

public enum APRSSymbol {
    /// Zellen, die in den mitgelieferten Blättern geleert sind (Markenlogos:
    /// `/M` Apple, `/Z` Windows, `\K` Kenwood) — dafür gibt es kein Bild.
    private static let withoutImage: Set<String> = ["0:M", "0:Z", "1:K"]

    /// nil bei unbekannter Tabelle, nicht druckbarem Code oder geleerter Zelle;
    /// die Karte zeigt dann einen neutralen Punkt.
    public static func sprite(table: Character, code: Character) -> APRSSymbolSprite? {
        guard let codeValue = code.asciiValue, (33...126).contains(codeValue),
              let tableValue = table.asciiValue else { return nil }
        let index = Int(codeValue) - 33
        let sheet: Int
        var overlay: Int?
        switch tableValue {
        case UInt8(ascii: "/"):
            sheet = 0
        case UInt8(ascii: "\\"):
            sheet = 1
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            // Overlay: Symbol aus der alternativen Tabelle, Zeichen darübergelegt.
            sheet = 1
            overlay = Int(tableValue) - 33
        default:
            return nil
        }
        guard !withoutImage.contains("\(sheet):\(code)") else { return nil }
        return APRSSymbolSprite(sheet: sheet, index: index, overlayIndex: overlay)
    }
}
