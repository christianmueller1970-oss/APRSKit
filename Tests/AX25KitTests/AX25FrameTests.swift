import XCTest
@testable import AX25Kit

final class AX25FrameTests: XCTestCase {

    // MARK: - Adressen

    func testAddressText() {
        XCTAssertEqual(AX25Address("N0CALL")?.text, "N0CALL")
        XCTAssertNil(AX25Address("n0call"))        // keine stille Umwandlung
        XCTAssertEqual(AX25Address("N0CALL-7")?.ssid, 7)
        XCTAssertEqual(AX25Address("WIDE1-1*")?.hasBeenRepeated, true)
        XCTAssertEqual(AX25Address("WIDE1-1*")?.text, "WIDE1-1*")
        XCTAssertEqual(AX25Address("N0CALL-0")?.text, "N0CALL")
        for bad in ["", "TOOLONG1", "N0 CAL", "N0CALL-16", "N0CALL-", "N0CALL-07", "N0CALL-A", "N0CÄLL", "-7", "qAR"] {
            XCTAssertNil(AX25Address(bad), bad)
        }
    }

    /// Zeichen um ein Bit geschoben, mit Leerzeichen aufgefüllt, SSID-Byte `c11ssss e`.
    func testAddressEncoding() {
        let address = AX25Address("N0CALL-7")!
        XCTAssertEqual(address.encoded(topBit: false, isLast: false), [0x9C, 0x60, 0x86, 0x82, 0x98, 0x98, 0x6E])
        XCTAssertEqual(address.encoded(topBit: true, isLast: true), [0x9C, 0x60, 0x86, 0x82, 0x98, 0x98, 0xEF])
        XCTAssertEqual(AX25Address("AB")!.encoded(topBit: false, isLast: true),
                       [0x82, 0x84, 0x40, 0x40, 0x40, 0x40, 0x61])
    }

    // MARK: - Rahmen

    func testFrameBytes() throws {
        let frame = try AX25Frame(tnc2: "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:>Test")
        let bytes = frame.bytes
        XCTAssertEqual(bytes.count, 7 * 4 + 2 + 5)
        // Ziel: C-Bit gesetzt, nicht letzter Eintrag.
        XCTAssertEqual(Array(bytes[0..<7]), [0x82, 0xA0, 0xB4, 0x90, 0x9A, 0xA8, 0xE0])
        // Quelle: C-Bit 0, SSID 7.
        XCTAssertEqual(bytes[13], 0x6E)
        // Letzter Digipeater trägt das Ende-Bit.
        XCTAssertEqual(bytes[20] & 0x01, 0)
        XCTAssertEqual(bytes[27], 0x60 | 1 << 1 | 1)
        XCTAssertEqual(Array(bytes[28..<30]), [0x03, 0xF0])
        XCTAssertEqual(Array(bytes[30...]), Array(">Test".utf8))
    }

    func testSourceIsLastWithoutDigipeaters() throws {
        let frame = try AX25Frame(tnc2: "N0CALL>APZHMT:>x")
        XCTAssertEqual(frame.bytes[13] & 0x01, 1)
        XCTAssertEqual(frame.bytes.count, 14 + 2 + 2)
    }

    func testTextRoundTrip() throws {
        for line in [
            "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:=4733.09N/00917.34ElHAM-Tools",
            "N0CALL>APZHMT:>x",
            "N0CALL-15>APZHMT,N0DIGI*,WIDE2-1::N0OTHER-9:Hallo: wie geht's{42",
            "A>B,C,D,E,F,G,H,I,J:!"
        ] {
            let frame = try AX25Frame(tnc2: line)
            XCTAssertEqual(String(decoding: frame.tnc2, as: UTF8.self), line)
            let decoded = try AX25Frame(bytes: frame.bytes)
            XCTAssertEqual(decoded, frame, line)
            XCTAssertEqual(String(decoding: decoded.tnc2, as: UTF8.self), line)
        }
    }

    /// Ein `*` gilt auch für alle Einträge davor; in der Textform steht er nur am letzten.
    func testRepeatedFlagCoversEarlierDigipeaters() throws {
        let frame = try AX25Frame(tnc2: "N0CALL>APZHMT,N0A,N0B*,WIDE2-1:>x")
        XCTAssertEqual(frame.digipeaters.map(\.hasBeenRepeated), [true, true, false])
        XCTAssertEqual(String(decoding: frame.tnc2, as: UTF8.self), "N0CALL>APZHMT,N0A,N0B*,WIDE2-1:>x")
        let decoded = try AX25Frame(bytes: frame.bytes)
        XCTAssertEqual(decoded.digipeaters.map(\.hasBeenRepeated), [true, true, false])
    }

    func testInformationKeepsEveryByte() throws {
        let info: [UInt8] = [0x60, 0x28, 0x5F, 0x66, 0x6E, 0x22, 0x4F, 0x6A, 0x2F, 0x1C, 0xFF, 0x00, 0x7E]
        let frame = try AX25Frame(tnc2: Array("N0CALL>S32U6T:".utf8) + info)
        XCTAssertEqual(frame.information, info)
        XCTAssertEqual(try AX25Frame(bytes: frame.bytes).information, info)
    }

    func testInvalidText() {
        func error(_ line: String) -> AX25Error? {
            do { _ = try AX25Frame(tnc2: line); return nil } catch { return error as? AX25Error }
        }
        XCTAssertEqual(error("N0CALL>APZHMT"), .malformedText)
        XCTAssertEqual(error("N0CALL:>x"), .malformedText)
        XCTAssertEqual(error("N0CALL>APZHMT:"), .emptyInformation)
        XCTAssertEqual(error("N0CALL-77>APZHMT:>x"), .invalidAddress("N0CALL-77"))
        XCTAssertEqual(error("N0CALL>APZHMT,TCPIP*,qAC,T2TEST:>x"), .invalidAddress("qAC"))
        XCTAssertEqual(error("N0CALL*>APZHMT:>x"), .invalidAddress("N0CALL*"))
        XCTAssertEqual(error("N0CALL>APZHMT,A,B,C,D,E,F,G,H,I:>x"), .tooManyDigipeaters)
        XCTAssertEqual(error("N0CALL>APZHMT:" + String(repeating: "x", count: 257)), .informationTooLong)
    }

    func testInvalidBytes() throws {
        let good = try AX25Frame(tnc2: "N0CALL-7>APZHMT,WIDE1-1:>Test").bytes
        func error(_ bytes: [UInt8]) -> AX25Error? {
            do { _ = try AX25Frame(bytes: bytes); return nil } catch { return error as? AX25Error }
        }
        XCTAssertEqual(error([]), .truncated)
        XCTAssertEqual(error(Array(good.prefix(10))), .truncated)
        XCTAssertEqual(error(Array(good.prefix(21))), .truncated)          // Adressen ohne Control/PID
        var noUI = good; noUI[21] = 0x13
        XCTAssertEqual(error(noUI), .notUIFrame)
        var endless = good; endless[20] &= 0xFE                            // Ende-Bit fehlt
        XCTAssertNotNil(error(endless))
        // Jede Verkürzung und jede Einzelbyte-Verfälschung: Fehler oder Rahmen, nie Absturz.
        for length in 0...good.count { _ = try? AX25Frame(bytes: Array(good.prefix(length))) }
        for index in good.indices {
            for value in [UInt8(0), 0x01, 0x7E, 0x80, 0xFF] {
                var corrupted = good
                corrupted[index] = value
                _ = try? AX25Frame(bytes: corrupted)
            }
        }
    }
}
