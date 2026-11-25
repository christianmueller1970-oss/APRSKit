import XCTest
@testable import APRSKit

/// Kopf und unkomprimierte Positionen. Die Positionsbeispiele folgen den
/// Beispielen der APRS Protocol Reference 1.0.1 (Kapitel 8); Rufzeichen frei gewählt.
final class APRSParserTests: XCTestCase {

    private func position(_ line: String, file: StaticString = #filePath, line l: UInt = #line) throws -> APRSPositionReport {
        let packet = try APRSParser.parse(line)
        guard case .position(let report) = packet.content else {
            XCTFail("Keine Position: \(line)", file: file, line: l)
            throw APRSParseError.empty
        }
        return report
    }

    // MARK: - Kopf

    func testHeaderWithPathAndQConstruct() throws {
        let packet = try APRSParser.parse("N0CALL-9>APRS,WIDE1-1*,WIDE2-1,qAR,N0GATE-10:>Status\r\n")
        XCTAssertEqual(packet.source, "N0CALL-9")
        XCTAssertEqual(packet.destination, "APRS")
        XCTAssertEqual(packet.path, [
            APRSPathElement(name: "WIDE1-1", isUsed: true),
            APRSPathElement(name: "WIDE2-1"),
            APRSPathElement(name: "qAR"),
            APRSPathElement(name: "N0GATE-10")
        ])
        XCTAssertEqual(packet.payloadText, ">Status")
        XCTAssertEqual(packet.dataTypeIdentifier, UInt8(ascii: ">"))
        XCTAssertEqual(packet.content, .status(APRSStatusReport(timestamp: nil, text: "Status")))
    }

    func testHeaderWithoutPath() throws {
        let packet = try APRSParser.parse("N0CALL>APRS:>x")
        XCTAssertEqual(packet.path, [])
    }

    func testPayloadKeepsLaterColons() throws {
        let packet = try APRSParser.parse("N0CALL>APRS::N0OTHER  :Hallo: Welt{12")
        XCTAssertEqual(packet.payloadText, ":N0OTHER  :Hallo: Welt{12")
    }

    func testSourceKeyIsNormalized() throws {
        XCTAssertEqual(try APRSParser.parse("n0call-9>APRS:>x").sourceKey, "N0CALL-9")
    }

    func testEmptyPayloadIsUnparsed() throws {
        let packet = try APRSParser.parse("N0CALL>APRS:")
        XCTAssertEqual(packet.payload, [])
        XCTAssertEqual(packet.content, .unparsed)
    }

    func testNonUTF8PayloadSurvives() throws {
        let bytes = Array("N0CALL>APRS:>Gr".utf8) + [0xFC, 0xDF] + Array("e".utf8)   // Latin-1 «üß»
        let packet = try APRSParser.parse(bytes)
        XCTAssertEqual(packet.payload.count, 6)
        XCTAssertEqual(packet.payloadText, ">Grüße")
    }

    func testHeaderErrors() {
        func error(_ line: String) -> APRSParseError? {
            do { _ = try APRSParser.parse(line); return nil } catch { return error as? APRSParseError }
        }
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("\r\n"), .empty)
        XCTAssertEqual(error("N0CALL>APRS"), .missingPayloadSeparator)
        XCTAssertEqual(error("N0CALL:>x"), .missingDestinationSeparator)
        XCTAssertEqual(error(">APRS:>x"), .invalidAddress)
        XCTAssertEqual(error("N0CALL>:>x"), .invalidAddress)
        XCTAssertEqual(error("N0CALL>APRS,,WIDE1-1:>x"), .invalidAddress)
        XCTAssertEqual(error("N0 CALL>APRS:>x"), .invalidAddress)
        XCTAssertEqual(error("N0CALL>APRS,WI*DE:>x"), .invalidAddress)
        XCTAssertEqual(error("N0CALL>APRS:" + String(repeating: "x", count: 600)), .tooLong)
    }

    // MARK: - Position

    func testPositionWithoutTimestamp() throws {
        let p = try position("N0CALL>APRS:!4903.50N/07201.75W-Test 001234")
        XCTAssertEqual(p.latitude, 49 + 3.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(p.longitude, -(72 + 1.75 / 60), accuracy: 1e-9)
        XCTAssertEqual(p.ambiguity, 0)
        XCTAssertEqual(p.symbolTable, "/")
        XCTAssertEqual(p.symbolCode, "-")
        XCTAssertNil(p.timestamp)
        XCTAssertFalse(p.supportsMessaging)
        XCTAssertEqual(p.comment, "Test 001234")
    }

    func testPositionWithMessaging() throws {
        let p = try position("N0CALL>APRS:=4903.50N/07201.75W-")
        XCTAssertTrue(p.supportsMessaging)
        XCTAssertEqual(p.comment, "")
    }

    func testPositionWithTimestamps() throws {
        let zulu = try position("N0CALL>APRS:/092345z4903.50N/07201.75W>Test1234")
        XCTAssertEqual(zulu.timestamp, .dayHourMinute(day: 9, hour: 23, minute: 45, isUTC: true))
        XCTAssertFalse(zulu.supportsMessaging)
        XCTAssertEqual(zulu.symbolCode, ">")
        XCTAssertEqual(zulu.comment, "Test1234")

        let local = try position("N0CALL>APRS:@092345/4903.50N/07201.75W>Test1234")
        XCTAssertEqual(local.timestamp, .dayHourMinute(day: 9, hour: 23, minute: 45, isUTC: false))
        XCTAssertTrue(local.supportsMessaging)

        let hms = try position("N0CALL>APRS:/234517h4903.50N/07201.75W>")
        XCTAssertEqual(hms.timestamp, .hourMinuteSecond(hour: 23, minute: 45, second: 17))
    }

    func testInvalidTimestampKeepsPosition() throws {
        let p = try position("N0CALL>APRS:/329999z4903.50N/07201.75W>")
        XCTAssertNil(p.timestamp)
        XCTAssertEqual(p.latitude, 49 + 3.5 / 60, accuracy: 1e-9)
    }

    func testSouthEastAndAlternateTable() throws {
        let p = try position("N0CALL>APRS:!3351.00S\\15112.50E#")
        XCTAssertEqual(p.latitude, -(33 + 51.0 / 60), accuracy: 1e-9)
        XCTAssertEqual(p.longitude, 151 + 12.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(p.symbolTable, "\\")
        XCTAssertEqual(p.symbolCode, "#")
    }

    func testAmbiguityUsesFieldCentre() throws {
        let cases: [(String, Int, Double, Double)] = [
            ("!4903.5 N/07201.7 W-", 1, 49 + 3.55 / 60, -(72 + 1.75 / 60)),
            ("!4903.  N/07201.  W-", 2, 49 + 3.5 / 60, -(72 + 1.5 / 60)),
            ("!490 .  N/0720 .  W-", 3, 49 + 5.0 / 60, -(72 + 5.0 / 60)),
            ("!49  .  N/072  .  W-", 4, 49.5, -72.5),
            // Längengrad voll ausgeschrieben: die Unschärfe des Breitengrads gilt trotzdem.
            ("!4903.  N/07201.75W-", 2, 49 + 3.5 / 60, -(72 + 1.5 / 60))
        ]
        for (payload, ambiguity, latitude, longitude) in cases {
            let p = try position("N0CALL>APRS:" + payload)
            XCTAssertEqual(p.ambiguity, ambiguity, payload)
            XCTAssertEqual(p.latitude, latitude, accuracy: 1e-9, payload)
            XCTAssertEqual(p.longitude, longitude, accuracy: 1e-9, payload)
        }
    }

    func testInvalidPositionsStayUnparsed() throws {
        let payloads = [
            "!9100.00N/07201.75W-",    // Breite > 90°
            "!4903.50N/18100.00W-",    // Länge > 180°
            "!4960.00N/07201.75W-",    // Minuten ≥ 60
            "!4903.50X/07201.75W-",    // Hemisphäre
            "!4903.50N/07201.75X-",
            "!4903,50N/07201.75W-",    // Dezimalpunkt
            "!49 3.50N/07201.75W-",    // Leerzeichen nicht von rechts
            "!4903.50N/07201.75W",     // Symbolcode fehlt
            "!4903.50N",               // abgeschnitten
            "/092345z4903.50N",
            "@0923",
            "!"
        ]
        for payload in payloads {
            let packet = try APRSParser.parse("N0CALL>APRS:" + payload)
            XCTAssertEqual(packet.content, .unparsed, payload)
            XCTAssertEqual(packet.payloadText, payload)
        }
    }

    // MARK: - Komprimierte Position

    /// Beispiel der Spezifikation (Kapitel 9): 49°30' N, 72°45' W, Kurs 88°, 36,2 kn.
    func testCompressedPositionWithCourseAndSpeed() throws {
        let p = try position("N0CALL>APRS:=/5L!!<*e7>7P[")
        XCTAssertEqual(p.latitude, 49.5, accuracy: 1e-4)
        XCTAssertEqual(p.longitude, -72.75, accuracy: 1e-4)
        XCTAssertEqual(p.symbolTable, "/")
        XCTAssertEqual(p.symbolCode, ">")
        XCTAssertEqual(p.course, 88)
        XCTAssertEqual(try XCTUnwrap(p.speedKnots), 36.2, accuracy: 0.05)
        XCTAssertNil(p.altitudeFeet)
        XCTAssertTrue(p.supportsMessaging)
        XCTAssertEqual(p.comment, "")
    }

    func testCompressedPositionWithoutCsData() throws {
        let p = try position("N0CALL>APRS:!/5L!!<*e7>  !Kommentar")
        XCTAssertNil(p.course)
        XCTAssertNil(p.speedKnots)
        XCTAssertEqual(p.comment, "Kommentar")
    }

    /// Spezifikation: cs `S]` = 10004 Fuss, wenn das Typ-Byte GGA als Quelle nennt.
    func testCompressedAltitude() throws {
        let p = try position("N0CALL>APRS:!/5L!!<*e7>S]1")
        XCTAssertEqual(try XCTUnwrap(p.altitudeFeet), 10004, accuracy: 1)
        XCTAssertNil(p.course)
    }

    /// Spezifikation: `{?` = Reichweite rund 20 Meilen.
    func testCompressedRadioRange() throws {
        let p = try position("N0CALL>APRS:!/5L!!<*e7>{?!")
        XCTAssertEqual(try XCTUnwrap(p.radioRangeMiles), 20.13, accuracy: 0.01)
        XCTAssertNil(p.course)
    }

    func testCompressedWithTimestampAndOverlay() throws {
        let p = try position("N0CALL>APRS:@092345zb5L!!<*e7#!4[x")
        XCTAssertEqual(p.timestamp, .dayHourMinute(day: 9, hour: 23, minute: 45, isUTC: true))
        XCTAssertEqual(p.symbolTable, "1")       // Overlay-Ziffer, übertragen als «b»
        XCTAssertEqual(p.symbolCode, "#")
        XCTAssertEqual(p.course, 360)            // 0 = Nord
        XCTAssertEqual(p.comment, "x")
    }

    func testInvalidCompressedStaysUnparsed() throws {
        for payload in ["!/5L!!<*e7>7P", "!x5L!!<*e7>7P[", "!/5L!!<*e\u{7F}>7P[", "!/5L~!<*e7>7P["] {
            XCTAssertEqual(try APRSParser.parse("N0CALL>APRS:" + payload).content, .unparsed, payload)
        }
    }

    // MARK: - Datenerweiterungen

    func testCourseAndSpeedExtension() throws {
        let p = try position("N0CALL>APRS:@092345/4903.50N/07201.75W>088/036 unterwegs")
        XCTAssertEqual(p.course, 88)
        XCTAssertEqual(p.speedKnots, 36)
        XCTAssertEqual(p.comment, " unterwegs")
    }

    func testUnknownCourseIsNil() throws {
        let zero = try position("N0CALL>APRS:!4903.50N/07201.75W>000/012")
        XCTAssertNil(zero.course)
        XCTAssertEqual(zero.speedKnots, 12)
        let dots = try position("N0CALL>APRS:!4903.50N/07201.75W>.../...")
        XCTAssertNil(dots.course)
        XCTAssertNil(dots.speedKnots)
        XCTAssertEqual(dots.comment, "")
    }

    /// Spezifikation: PHG5132 = 25 W, 20 Fuss, 3 dB, Richtung Ost.
    func testPHGExtension() throws {
        let p = try position("N0CALL>APRS:=4903.50N/07201.75W#PHG5132Digi")
        XCTAssertEqual(p.phg, APRSPHG(powerWatts: 25, heightFeet: 20, gainDb: 3, directivityDegrees: 90))
        XCTAssertEqual(p.comment, "Digi")
        let omni = try position("N0CALL>APRS:=4903.50N/07201.75W#PHG2360")
        XCTAssertEqual(omni.phg, APRSPHG(powerWatts: 4, heightFeet: 80, gainDb: 6, directivityDegrees: nil))
    }

    /// APRS 1.2: `PHG72604/` trägt zusätzlich die Baken pro Stunde.
    func testPHGWithBeaconRate() throws {
        let p = try position("N0CALL>APRS:=4903.50N/07201.75W#PHG72604/Digi")
        XCTAssertEqual(p.phg, APRSPHG(powerWatts: 49, heightFeet: 40, gainDb: 6, directivityDegrees: nil))
        XCTAssertEqual(p.comment, "Digi")
    }

    /// Beispiel der Spezifikation: Höhe im Kommentar.
    func testSpecAltitudeExample() throws {
        let p = try position("N0CALL>APRS:!4903.50N/07201.75W-Test /A=001234")
        XCTAssertEqual(p.altitudeFeet, 1234)
        XCTAssertEqual(p.comment, "Test ")
    }

    func testRangeExtension() throws {
        let p = try position("N0CALL>APRS:=4903.50N/07201.75W#RNG0050")
        XCTAssertEqual(p.radioRangeMiles, 50)
    }

    func testAltitudeInComment() throws {
        let p = try position("N0CALL>APRS:!4903.50N/07201.75W>088/036 QRV /A=001234 73")
        XCTAssertEqual(p.altitudeFeet, 1234)
        XCTAssertEqual(p.comment, " QRV  73")
        let below = try position("N0CALL>APRS:!4903.50N/07201.75W-/A=-00042")
        XCTAssertEqual(below.altitudeFeet, -42)
        let compressed = try position("N0CALL>APRS:=/5L!!<*e7>7P[/A=000500")
        XCTAssertEqual(compressed.altitudeFeet, 500)
        XCTAssertEqual(compressed.course, 88)
    }

    func testTextThatOnlyLooksLikeAnExtension() throws {
        let p = try position("N0CALL>APRS:!4903.50N/07201.75W-PHG kaputt /A=12")
        XCTAssertNil(p.phg)
        XCTAssertNil(p.altitudeFeet)
        XCTAssertEqual(p.comment, "PHG kaputt /A=12")
    }

    /// Beim Wettersymbol ist `DDD/SSS` der Wind, nicht Kurs und Geschwindigkeit.
    func testWeatherSymbolTreatsLeadingFieldsAsWind() throws {
        let p = try position("N0CALL>APRS:!4903.50N/07201.75W_220/004g005t077")
        XCTAssertNil(p.course)
        XCTAssertNil(p.speedKnots)
        XCTAssertEqual(p.weather?.windDirectionDegrees, 220)
        XCTAssertEqual(p.weather?.windSpeedMph, 4)
        XCTAssertEqual(p.comment, "")
    }

    // MARK: - Robustheit

    /// Jedes abgeschnittene oder an einer Stelle verfälschte Paket darf werfen
    /// oder `.unparsed` liefern, aber nie abstürzen.
    func testTruncatedAndCorruptedLinesNeverCrash() {
        let lines = [
            "N0CALL-9>APRS,WIDE1-1*,qAR,N0GATE-10:!4903.50N/07201.75W-Test 001234",
            "N0CALL>APRS:@092345/4903.50N/07201.75W>Test1234",
            "N0CALL>APRS:/234517h49  .  N/072  .  W>",
            "N0CALL>APRS:@092345zb5L!!<*e7#!4[x",
            "N0CALL>APRS:!4903.50N/07201.75W>088/036 QRV /A=001234",
            "N0CALL>APRS:=4903.50N/07201.75W#PHG5132/A=-00042"
        ]
        var generator = SystemRandomNumberGenerator()
        for line in lines {
            let bytes = Array(line.utf8)
            for length in 0...bytes.count {
                _ = try? APRSParser.parse(Array(bytes.prefix(length)))
            }
            for index in bytes.indices {
                for _ in 0..<32 {
                    var corrupted = bytes
                    corrupted[index] = UInt8.random(in: 0...255, using: &generator)
                    _ = try? APRSParser.parse(corrupted)
                }
            }
        }
    }
}
