import Foundation

/// HDLC-Rahmung von AX.25: FCS, Bit-Stuffing und Flags. Bits laufen mit dem
/// niederwertigsten Bit jedes Bytes zuerst.
public enum HDLC {
    public static let flag: UInt8 = 0x7E

    /// CRC-16 nach X.25 (Polynom 0x1021 gespiegelt = 0x8408, Startwert 0xFFFF,
    /// Ergebnis invertiert). Prüfwert für die ASCII-Folge «123456789»: 0x906E.
    public static func fcs(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return ~crc
    }

    /// Bitfolge einer Aussendung: Vorlauf-Flags, Rahmen mit FCS (gestopft),
    /// Nachlauf-Flags. Noch ohne NRZI — das macht der Modulator.
    public static func bits(frame: [UInt8], leadingFlags: Int, trailingFlags: Int) -> [Bool] {
        var bits: [Bool] = []
        bits.reserveCapacity((frame.count + 2) * 9 + (leadingFlags + trailingFlags) * 8)
        func appendFlags(_ count: Int) {
            for _ in 0..<max(1, count) {
                for bit in 0..<8 { bits.append(flag >> UInt8(bit) & 1 != 0) }
            }
        }
        appendFlags(leadingFlags)
        let check = fcs(frame)
        var ones = 0
        // FCS: niederwertiges Byte zuerst.
        for byte in frame + [UInt8(check & 0xFF), UInt8(check >> 8)] {
            for bit in 0..<8 {
                let value = byte >> UInt8(bit) & 1 != 0
                bits.append(value)
                ones = value ? ones + 1 : 0
                // Nach fünf Einsen eine Null einfügen, damit im Rahmen nie ein Flag entsteht.
                if ones == 5 {
                    bits.append(false)
                    ones = 0
                }
            }
        }
        appendFlags(trailingFlags)
        return bits
    }
}

/// Zerlegt einen Bitstrom (nach NRZI) wieder in Rahmen: Flags erkennen,
/// gestopfte Nullen entfernen, FCS prüfen. Liefert nur Rahmen mit gültiger FCS,
/// ohne Flags und ohne FCS.
public struct HDLCDeframer: Sendable {
    /// Kürzester sinnvoller Rahmen: zwei Adressen, Control, PID, FCS.
    public static let minFrameBytes = 18
    public static let maxFrameBytes = 7 * 10 + 2 + AX25Frame.maxInformationBytes + 2

    public private(set) var rejectedFrames = 0
    private var ones = 0
    private var inFrame = false
    private var bitBuffer: [Bool] = []

    public init() {}

    public mutating func append<S: Sequence>(_ bits: S) -> [[UInt8]] where S.Element == Bool {
        var frames: [[UInt8]] = []
        for bit in bits {
            if bit {
                ones += 1
                // Sieben Einsen in Folge: Abbruch, kein gültiger Rahmen.
                if ones >= 7 {
                    inFrame = false
                    bitBuffer.removeAll(keepingCapacity: true)
                } else if inFrame {
                    bitBuffer.append(true)
                }
                continue
            }
            if ones == 6 {
                // Flag: die sechs Einsen und die führende Null davor gehören nicht zum Rahmen.
                if inFrame, bitBuffer.count >= 7 {
                    bitBuffer.removeLast(7)
                    if let frame = finish() { frames.append(frame) }
                }
                inFrame = true
                bitBuffer.removeAll(keepingCapacity: true)
            } else if ones == 5 {
                // Gestopfte Null: verwerfen.
            } else if inFrame {
                bitBuffer.append(false)
            }
            ones = 0
            // Spielraum für die sieben Bits des schliessenden Flags, die erst bei
            // dessen Erkennung wieder entfernt werden (Codex-Review 21.11.2026).
            if bitBuffer.count > Self.maxFrameBytes * 8 + 7 {
                inFrame = false
                bitBuffer.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }

    private mutating func finish() -> [UInt8]? {
        guard !bitBuffer.isEmpty else { return nil }
        guard bitBuffer.count % 8 == 0, bitBuffer.count >= Self.minFrameBytes * 8 else {
            rejectedFrames += 1
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(bitBuffer.count / 8)
        var index = 0
        while index < bitBuffer.count {
            var byte: UInt8 = 0
            for bit in 0..<8 where bitBuffer[index + bit] { byte |= 1 << UInt8(bit) }
            bytes.append(byte)
            index += 8
        }
        let payload = Array(bytes.dropLast(2))
        let received = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        guard HDLC.fcs(payload) == received else {
            rejectedFrames += 1
            return nil
        }
        return payload
    }
}
