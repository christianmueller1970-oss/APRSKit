import Foundation

/// Status (`>`) und Messages (`:`).
enum APRSMessageDecoder {
    private static let addresseeLength = 9
    private static let timestampLength = 7
    private static let maxIDLength = 5

    static func decodeStatus(_ payload: ArraySlice<UInt8>) -> APRSStatusReport {
        var rest = payload.dropFirst()
        var timestamp: APRSTimestamp?
        // Im Status ist nur `DDHHMMz` vorgesehen.
        if rest.count >= timestampLength,
           rest[rest.index(rest.startIndex, offsetBy: timestampLength - 1)] == UInt8(ascii: "z"),
           let parsed = APRSPositionDecoder.decodeTimestamp(rest.prefix(timestampLength)) {
            timestamp = parsed
            rest = rest.dropFirst(timestampLength)
        }
        return APRSStatusReport(timestamp: timestamp, text: APRSText.decode(rest))
    }

    /// `:ADRESSAT :Text{Nr` — Adressat immer neun Zeichen, mit Leerzeichen aufgefüllt.
    static func decodeMessage(_ payload: ArraySlice<UInt8>) -> APRSMessage? {
        var rest = payload.dropFirst()
        guard rest.count > addresseeLength,
              rest[rest.index(rest.startIndex, offsetBy: addresseeLength)] == UInt8(ascii: ":") else {
            return nil
        }
        let addresseeBytes = rest.prefix(addresseeLength)
        guard addresseeBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let addressee = String(decoding: addresseeBytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !addressee.isEmpty else { return nil }
        rest = rest.dropFirst(addresseeLength + 1)

        let body = Array(rest)
        for (prefix, kind) in [("ack", APRSMessage.Kind.ack), ("rej", APRSMessage.Kind.reject)] {
            if body.starts(with: Array(prefix.utf8)),
               let ids = identifiers(body[prefix.utf8.count...]) {
                return APRSMessage(addressee: addressee, kind: kind, text: "",
                                   messageID: ids.id, replyAckID: nil)
            }
        }

        // Die Laufnummer steht hinter der letzten `{`; passt der Rest nicht
        // als Nummer, gehört die Klammer zum Text.
        if let brace = body.lastIndex(of: UInt8(ascii: "{")),
           let ids = identifiers(body[(brace + 1)...]) {
            return APRSMessage(addressee: addressee, kind: .text,
                               text: APRSText.decode(body[..<brace]),
                               messageID: ids.id, replyAckID: ids.replyAck)
        }
        return APRSMessage(addressee: addressee, kind: .text, text: APRSText.decode(body[...]),
                           messageID: nil, replyAckID: nil)
    }

    /// `Nr` oder Reply-Ack `MM}AA` (auch `MM}` ohne Bestätigung).
    private static func identifiers(_ bytes: ArraySlice<UInt8>) -> (id: String, replyAck: String?)? {
        let parts = bytes.split(separator: UInt8(ascii: "}"), maxSplits: 1,
                                omittingEmptySubsequences: false)
        guard let first = parts.first, let id = identifier(first) else { return nil }
        guard parts.count == 2 else { return (id, nil) }
        if parts[1].isEmpty { return (id, nil) }
        guard let replyAck = identifier(parts[1]) else { return nil }
        return (id, replyAck)
    }

    private static func identifier(_ bytes: ArraySlice<UInt8>) -> String? {
        guard (1...maxIDLength).contains(bytes.count), bytes.allSatisfy(isAlphanumeric) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
}
