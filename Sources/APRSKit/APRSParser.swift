import Foundation

public enum APRSParseError: Error, Equatable, Sendable {
    case empty
    case tooLong
    /// Kein `:` zwischen Kopf und Nutzdaten.
    case missingPayloadSeparator
    /// Kein `>` zwischen Quelle und Ziel.
    case missingDestinationSeparator
    case invalidAddress
}

/// Parser für Pakete im TNC2-Textformat. Reine Funktionen, kein Zustand.
///
/// Ein Fehler wird nur geworfen, wenn der Kopf nicht lesbar ist. Passen die
/// Nutzdaten nicht zu ihrem Typ, entsteht ein Paket mit `.unparsed`.
public enum APRSParser {
    /// Obergrenze für eine Zeile. APRS-IS begrenzt Zeilen auf 512 Bytes
    /// (noch gegen aprs-is.net zu verifizieren, siehe Plan).
    public static let maxLineBytes = 512
    /// Grosszügiger als AX.25 (6 Zeichen + SSID): APRS-IS kennt auch
    /// Servernamen und q-Konstrukte im Pfad.
    static let maxAddressBytes = 16

    public static func parse(_ line: String) throws -> APRSPacket {
        try parse(Array(line.utf8))
    }

    public static func parse(_ bytes: [UInt8]) throws -> APRSPacket {
        try parse(bytes, depth: 0)
    }

    /// Third-Party-Pakete dürfen genau ein inneres Paket auspacken; tiefer
    /// verschachtelte bleiben Rohpakete.
    static let maxThirdPartyDepth = 1

    private static func parse(_ bytes: [UInt8], depth: Int) throws -> APRSPacket {
        var line = bytes[...]
        while let last = line.last, last == 0x0D || last == 0x0A { line = line.dropLast() }
        guard !line.isEmpty else { throw APRSParseError.empty }
        guard line.count <= maxLineBytes else { throw APRSParseError.tooLong }

        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else {
            throw APRSParseError.missingPayloadSeparator
        }
        let header = line[line.startIndex..<colon]
        let payload = line[line.index(after: colon)...]

        guard let separator = header.firstIndex(of: UInt8(ascii: ">")) else {
            throw APRSParseError.missingDestinationSeparator
        }
        let source = try address(header[header.startIndex..<separator])
        let fields = header[header.index(after: separator)...]
            .split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
        guard let first = fields.first else { throw APRSParseError.invalidAddress }
        let destination = try address(first)

        var path: [APRSPathElement] = []
        path.reserveCapacity(fields.count - 1)
        for field in fields.dropFirst() {
            let isUsed = field.last == UInt8(ascii: "*")
            path.append(APRSPathElement(name: try address(isUsed ? field.dropLast() : field),
                                        isUsed: isUsed))
        }

        return APRSPacket(source: source, destination: destination, path: path,
                          payload: Array(payload),
                          content: content(of: payload, destination: first, depth: depth))
    }

    private static func address(_ bytes: ArraySlice<UInt8>) throws -> String {
        guard !bytes.isEmpty, bytes.count <= maxAddressBytes else {
            throw APRSParseError.invalidAddress
        }
        for byte in bytes {
            // Druckbares ASCII ohne Leerzeichen; `*` nur als abgetrennte Endung.
            guard byte > 0x20, byte < 0x7F, byte != UInt8(ascii: "*") else {
                throw APRSParseError.invalidAddress
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func content(of payload: ArraySlice<UInt8>, destination: ArraySlice<UInt8>,
                                depth: Int) -> APRSContent {
        guard let type = payload.first else { return .unparsed }
        switch type {
        case UInt8(ascii: "!"), UInt8(ascii: "="), UInt8(ascii: "/"), UInt8(ascii: "@"):
            return APRSPositionDecoder.decode(payload).map(APRSContent.position) ?? .unparsed
        case UInt8(ascii: "`"), UInt8(ascii: "'"):
            return APRSMicEDecoder.decode(payload, destination: destination)
                .map(APRSContent.position) ?? .unparsed
        case UInt8(ascii: ";"):
            return APRSObjectDecoder.decodeObject(payload).map(APRSContent.object) ?? .unparsed
        case UInt8(ascii: ")"):
            return APRSObjectDecoder.decodeItem(payload).map(APRSContent.item) ?? .unparsed
        case UInt8(ascii: ">"):
            return .status(APRSMessageDecoder.decodeStatus(payload))
        case UInt8(ascii: ":"):
            return APRSMessageDecoder.decodeMessage(payload).map(APRSContent.message) ?? .unparsed
        case UInt8(ascii: "_"):
            return APRSWeatherDecoder.decodePositionless(payload).map(APRSContent.weather) ?? .unparsed
        case UInt8(ascii: "T"):
            return APRSTelemetryDecoder.decode(payload).map(APRSContent.telemetry) ?? .unparsed
        case UInt8(ascii: "}"):
            guard depth < maxThirdPartyDepth,
                  let inner = try? parse(Array(payload.dropFirst()), depth: depth + 1) else {
                return .unparsed
            }
            return .thirdParty(inner)
        default:
            return .unparsed
        }
    }
}
