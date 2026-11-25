import XCTest
@testable import APRSKit

final class APRSMicETests: XCTestCase {

    private func position(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws -> APRSPositionReport {
        guard case .position(let report) = try APRSParser.parse(bytes).content else {
            XCTFail("Keine Position", file: file, line: line)
            throw APRSParseError.empty
        }
        return report
    }

    private func line(_ destination: String, _ info: [UInt8]) -> [UInt8] {
        Array("N0CALL-9>\(destination),WIDE1-1:".utf8) + info
    }

    /// Reales Paket (Testvektor des Parsers Ham::APRS::FAP, Rufzeichen ersetzt):
    /// 38°15.36' S, 145°11.16' E, steht, Symbol Auto, Typ-Byte `]`.
    func testRealPacketSouthEastWithOffset() throws {
        let info: [UInt8] = Array("'I',l ".utf8) + [0x1C] + Array(">/]".utf8)
        let p = try position(line("SX15S6", info))
        XCTAssertEqual(p.latitude, -38.2560, accuracy: 1e-4)
        XCTAssertEqual(p.longitude, 145.1860, accuracy: 1e-4)
        XCTAssertEqual(p.speedKnots, 0)
        XCTAssertNil(p.course)
        XCTAssertEqual(p.symbolCode, ">")
        XCTAssertEqual(p.symbolTable, "/")
        XCTAssertEqual(p.ambiguity, 0)
        XCTAssertEqual(p.comment, "]")
        // S und X aus P…Y (Standard-Bit 1), «1» = 0 → 110 = M1 En Route.
        XCTAssertEqual(p.micEStatus, .standard(1))
    }

    /// Zieladresse und Daten nach dem Beispiel der Spezifikation: 33°25.64' N,
    /// 20 kn, Kurs 251°, Meldung M3. Erwartungswerte aus dem Verfahren berechnet.
    func testNorthWestWithSpeedAndCourse() throws {
        let p = try position(line("S32U6T", Array("`(_fn\"Oj/".utf8)))
        XCTAssertEqual(p.latitude, 33 + 25.64 / 60, accuracy: 1e-6)
        XCTAssertEqual(p.longitude, -(12 + 7.74 / 60), accuracy: 1e-6)
        XCTAssertEqual(p.speedKnots, 20)
        XCTAssertEqual(p.course, 251)
        XCTAssertEqual(p.symbolCode, "j")
        XCTAssertEqual(p.micEStatus, .standard(3))
        XCTAssertEqual(p.comment, "")
    }

    func testLongitudeOffsetAndSSIDInDestination() throws {
        // Fünftes Zeichen aus P…Y: +100° → 112° W.
        let p = try position(line("S32UVT-2", Array("`(_fn\"Oj/".utf8)))
        XCTAssertEqual(p.longitude, -(112 + 7.74 / 60), accuracy: 1e-6)
        XCTAssertEqual(p.latitude, 33 + 25.64 / 60, accuracy: 1e-6)
    }

    func testAmbiguityFromDestination() throws {
        // «Z» und «L» stehen für Leerzeichen: 33°25.6_' → Unschärfe 1.
        let one = try position(line("S32U6Z", Array("`(_fn\"Oj/".utf8)))
        XCTAssertEqual(one.ambiguity, 1)
        XCTAssertEqual(one.latitude, 33 + 25.65 / 60, accuracy: 1e-6)
        XCTAssertEqual(one.longitude, -(12 + 7.75 / 60), accuracy: 1e-6)
        let two = try position(line("S32UZZ", Array("`(_fn\"Oj/".utf8)))
        XCTAssertEqual(two.ambiguity, 2)
        XCTAssertEqual(two.latitude, 33 + 25.5 / 60, accuracy: 1e-6)
    }

    func testMessageBits() throws {
        let info = Array("`(_fn\"Oj/".utf8)
        XCTAssertEqual(try position(line("SSRU6T", info)).micEStatus, .standard(0))   // 111
        XCTAssertEqual(try position(line("332U6T", info)).micEStatus, .emergency)     // 000
        XCTAssertEqual(try position(line("DDCU6T", info)).micEStatus, .custom(0))     // Custom 111
        XCTAssertEqual(try position(line("D32U6T", info)).micEStatus, .custom(3))     // Custom 100
        XCTAssertNil(try position(line("SD2U6T", info)).micEStatus)                   // gemischt
    }

    /// Höhe: `"4T}` = 61 m über Meer (10 061 = 1·91² + 19·91 + 51).
    func testAltitude() throws {
        let p = try position(line("S32U6T", Array("`(_fn\"Oj/]\"4T}QRV".utf8)))
        XCTAssertEqual(try XCTUnwrap(p.altitudeFeet), 61 / 0.3048, accuracy: 0.01)
        XCTAssertEqual(p.comment, "]QRV")
    }

    func testInvalidMicEStaysUnparsed() throws {
        let info = Array("`(_fn\"Oj/".utf8)
        let cases: [[UInt8]] = [
            line("APRS", info),                         // Zieladresse zu kurz
            line("S32A6T", info),                       // Custom-Zeichen an Stelle 4
            line("S32U6M", info),                       // M ist kein gültiges Zeichen
            line("Y92U6T", info),                       // 99° Breite
            line("S32U6T", Array("`(_fn\"Oj".utf8)),    // Symboltabelle fehlt
            line("S32U6T", Array("`(_fn\"Oj!".utf8)),   // ungültige Symboltabelle
            line("S32U6T", Array("`(zfn\"Oj/".utf8)),   // Minuten ausserhalb
            line("S32U6T", Array("`".utf8))
        ]
        for bytes in cases {
            XCTAssertEqual(try APRSParser.parse(bytes).content, .unparsed,
                           String(decoding: bytes, as: UTF8.self))
        }
    }

    func testTruncatedAndCorruptedLinesNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        let bytes = line("S32U6T", Array("`(_fn\"Oj/]\"4T}QRV".utf8))
        for length in 0...bytes.count {
            _ = try? APRSParser.parse(Array(bytes.prefix(length)))
        }
        for index in bytes.indices {
            for value in UInt8.min...UInt8.max {
                var corrupted = bytes
                corrupted[index] = value
                _ = try? APRSParser.parse(corrupted)
            }
            var corrupted = bytes
            corrupted[index] = UInt8.random(in: 0...255, using: &generator)
            corrupted[bytes.count - 1 - index] = UInt8.random(in: 0...255, using: &generator)
            _ = try? APRSParser.parse(corrupted)
        }
    }
}
