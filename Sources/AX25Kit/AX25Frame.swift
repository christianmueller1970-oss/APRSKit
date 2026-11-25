import Foundation

/// Eine AX.25-Adresse: Rufzeichen (bis sechs Zeichen), SSID 0–15 und ein Flag.
/// Bei Digipeatern ist das Flag das H-Bit («hat das Paket weitergereicht»).
public struct AX25Address: Equatable, Sendable {
    public let callsign: String
    public let ssid: Int
    public let hasBeenRepeated: Bool

    /// nil, wenn das Rufzeichen nicht ins AX.25-Format passt: ein bis sechs
    /// Grossbuchstaben oder Ziffern, SSID 0–15. Kleinbuchstaben werden nicht
    /// stillschweigend umgewandelt: so kann ein q-Konstrukt aus dem Internet
    /// (`qAR`, `qAC`) nie als Digipeater auf Funk landen.
    public init?(callsign: String, ssid: Int = 0, hasBeenRepeated: Bool = false) {
        let call = callsign
        let bytes = Array(call.utf8)
        guard (1...6).contains(bytes.count), (0...15).contains(ssid),
              bytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
        self.callsign = call
        self.ssid = ssid
        self.hasBeenRepeated = hasBeenRepeated
    }

    /// Aus der Textform `CALL`, `CALL-7` oder `CALL-7*`.
    public init?(_ text: String) {
        var body = text
        let repeated = body.hasSuffix("*")
        if repeated { body.removeLast() }
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let call = parts.first else { return nil }
        var ssid = 0
        if parts.count == 2 {
            guard let value = Int(parts[1]), String(value) == parts[1] else { return nil }
            ssid = value
        }
        self.init(callsign: String(call), ssid: ssid, hasBeenRepeated: repeated)
    }

    public var text: String {
        (ssid == 0 ? callsign : "\(callsign)-\(ssid)") + (hasBeenRepeated ? "*" : "")
    }

    /// Sieben Bytes: sechs Zeichen um ein Bit nach links geschoben (mit
    /// Leerzeichen aufgefüllt), dann das SSID-Byte `c11ssss e`.
    func encoded(topBit: Bool, isLast: Bool) -> [UInt8] {
        var bytes = Array(callsign.utf8).map { $0 << 1 }
        bytes += Array(repeating: UInt8(ascii: " ") << 1, count: 6 - bytes.count)
        bytes.append((topBit ? 0x80 : 0) | 0x60 | UInt8(ssid) << 1 | (isLast ? 1 : 0))
        return bytes
    }
}

public enum AX25Error: Error, Equatable, Sendable {
    case malformedText
    case invalidAddress(String)
    case tooManyDigipeaters
    case emptyInformation
    case informationTooLong
    case truncated
    case notUIFrame
}

/// AX.25-UI-Rahmen, wie ihn APRS verwendet: Ziel, Quelle, bis zu acht
/// Digipeater, Control `0x03`, PID `0xF0`, Information. Ohne Flags und FCS.
public struct AX25Frame: Equatable, Sendable {
    public static let control: UInt8 = 0x03
    public static let protocolID: UInt8 = 0xF0
    public static let maxDigipeaters = 8
    public static let maxInformationBytes = 256

    public let destination: AX25Address
    public let source: AX25Address
    public let digipeaters: [AX25Address]
    public let information: [UInt8]

    public init(destination: AX25Address, source: AX25Address, digipeaters: [AX25Address] = [],
                information: [UInt8]) throws {
        guard digipeaters.count <= Self.maxDigipeaters else { throw AX25Error.tooManyDigipeaters }
        guard !information.isEmpty else { throw AX25Error.emptyInformation }
        guard information.count <= Self.maxInformationBytes else { throw AX25Error.informationTooLong }
        self.destination = destination
        self.source = source
        self.digipeaters = digipeaters
        self.information = information
    }

    // MARK: - TNC2-Text

    /// Aus `QUELLE>ZIEL,PFAD:Nutzdaten`. Ein `*` gilt wie im TNC2-Format für
    /// den Eintrag selbst und alle davor.
    public init(tnc2 line: [UInt8]) throws {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")),
              let separator = line[..<colon].firstIndex(of: UInt8(ascii: ">")) else {
            throw AX25Error.malformedText
        }
        let sourceText = String(decoding: line[..<separator], as: UTF8.self)
        let fields = line[(separator + 1)..<colon].split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let destinationText = fields.first else { throw AX25Error.malformedText }
        guard let source = AX25Address(sourceText), !source.hasBeenRepeated else {
            throw AX25Error.invalidAddress(sourceText)
        }
        guard let destination = AX25Address(destinationText), !destination.hasBeenRepeated else {
            throw AX25Error.invalidAddress(destinationText)
        }
        var path: [AX25Address] = []
        for text in fields.dropFirst() {
            guard let address = AX25Address(text) else { throw AX25Error.invalidAddress(text) }
            path.append(address)
        }
        if let lastUsed = path.lastIndex(where: \.hasBeenRepeated) {
            path = path.enumerated().map { index, address in
                index <= lastUsed
                    ? AX25Address(callsign: address.callsign, ssid: address.ssid, hasBeenRepeated: true)!
                    : address
            }
        }
        try self.init(destination: destination, source: source, digipeaters: path,
                      information: Array(line[(colon + 1)...]))
    }

    public init(tnc2 line: String) throws {
        try self.init(tnc2: Array(line.utf8))
    }

    /// TNC2-Textform; der `*` steht nur am letzten benutzten Digipeater.
    public var tnc2: [UInt8] {
        var header = source.text + ">" + destination.text
        let lastUsed = digipeaters.lastIndex(where: \.hasBeenRepeated)
        for (index, address) in digipeaters.enumerated() {
            let plain = AX25Address(callsign: address.callsign, ssid: address.ssid)!
            header += "," + plain.text + (index == lastUsed ? "*" : "")
        }
        return Array((header + ":").utf8) + information
    }

    // MARK: - Bytes

    /// Rahmen ohne Flags und FCS. UI-Rahmen sind Kommandos: C-Bit im Ziel 1,
    /// in der Quelle 0.
    public var bytes: [UInt8] {
        var result = destination.encoded(topBit: true, isLast: false)
        result += source.encoded(topBit: false, isLast: digipeaters.isEmpty)
        for (index, address) in digipeaters.enumerated() {
            result += address.encoded(topBit: address.hasBeenRepeated, isLast: index == digipeaters.count - 1)
        }
        result += [Self.control, Self.protocolID]
        return result + information
    }

    /// Liest einen Rahmen ohne Flags und FCS. Die C-Bits von Ziel und Quelle
    /// werden ignoriert — in der Praxis sind sie uneinheitlich gesetzt.
    public init(bytes: [UInt8]) throws {
        var addresses: [AX25Address] = []
        var offset = 0
        var isLast = false
        while !isLast {
            guard offset + 7 <= bytes.count else { throw AX25Error.truncated }
            guard addresses.count < 2 + Self.maxDigipeaters else { throw AX25Error.tooManyDigipeaters }
            let field = bytes[offset..<(offset + 7)]
            let characters = field.prefix(6).map { $0 >> 1 }
            let call = String(decoding: characters, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let last = field[field.startIndex + 6]
            // Nur bei Digipeatern bedeutet das oberste Bit «weitergereicht».
            let repeated = addresses.count >= 2 && last & 0x80 != 0
            guard let address = AX25Address(callsign: call, ssid: Int(last >> 1 & 0x0F), hasBeenRepeated: repeated) else {
                throw AX25Error.invalidAddress(call)
            }
            addresses.append(address)
            isLast = last & 0x01 != 0
            offset += 7
        }
        guard addresses.count >= 2 else { throw AX25Error.truncated }
        guard offset + 2 <= bytes.count else { throw AX25Error.truncated }
        guard bytes[offset] == Self.control, bytes[offset + 1] == Self.protocolID else { throw AX25Error.notUIFrame }
        try self.init(destination: addresses[0], source: addresses[1],
                      digipeaters: Array(addresses.dropFirst(2)), information: Array(bytes[(offset + 2)...]))
    }
}
