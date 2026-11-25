import XCTest
@testable import APRSKit

final class APRSEncoderTests: XCTestCase {

    // MARK: - Passcode

    /// Allgemein bekannter Testwert: N0CALL → 13023.
    func testPasscodeKnownValue() {
        XCTAssertEqual(APRSIS.passcode(for: "N0CALL"), 13023)
        XCTAssertEqual(APRSIS.passcode(for: " n0call-9 "), 13023)     // SSID und Schreibweise zählen nicht
    }

    func testPasscodeEdgeCases() {
        XCTAssertNil(APRSIS.passcode(for: ""))
        XCTAssertNil(APRSIS.passcode(for: "-9"))
        XCTAssertNil(APRSIS.passcode(for: "HB9ÄÖ"))
        for call in ["A", "AB", "HB9XYZ", "W1AW", "DL1ABC"] {
            let code = APRSIS.passcode(for: call)
            XCTAssertNotNil(code)
            XCTAssertTrue((0...0x7FFF).contains(code ?? -1), call)
        }
    }

    // MARK: - Zeile

    func testLine() {
        XCTAssertEqual(APRSEncoder.line(source: "n0call-7", payload: ">Test"), "N0CALL-7>APZHMT,TCPIP*:>Test")
        XCTAssertNil(APRSEncoder.line(source: "N0 CALL", payload: ">Test"))
        XCTAssertNil(APRSEncoder.line(source: "N0CALL", payload: ""))
        XCTAssertNil(APRSEncoder.line(source: "N0CALL", payload: ">Zeile\r\nN0CALL>APRS:>zweite"))
    }

    // MARK: - Position

    func testPositionRoundTrip() throws {
        let payload = try XCTUnwrap(APRSEncoder.position(
            latitude: 47.5612, longitude: 9.2934, symbolTable: "/", symbolCode: "-",
            altitudeFeet: 1473, comment: "HAM-Tools Test"))
        XCTAssertEqual(payload, "=4733.67N/00917.60E-/A=001473HAM-Tools Test")
        let packet = try APRSParser.parse(try XCTUnwrap(APRSEncoder.line(source: "N0CALL-7", payload: payload)))
        guard case .position(let report) = packet.content else { return XCTFail("Keine Position") }
        XCTAssertEqual(report.latitude, 47.5612, accuracy: 0.0001)
        XCTAssertEqual(report.longitude, 9.2934, accuracy: 0.0001)
        XCTAssertEqual(report.symbolCode, "-")
        XCTAssertEqual(report.altitudeFeet, 1473)
        XCTAssertTrue(report.supportsMessaging)
        XCTAssertEqual(report.comment, "HAM-Tools Test")
        XCTAssertEqual(packet.destination, "APZHMT")
    }

    func testPositionHemispheresAndRounding() throws {
        XCTAssertEqual(APRSEncoder.position(latitude: -33.85, longitude: -70.5, symbolTable: "\\", symbolCode: "&",
                                            supportsMessaging: false),
                       "!3351.00S\\07030.00W&")
        // 59,996 Minuten runden auf den nächsten Grad, nie auf «60.00».
        XCTAssertEqual(APRSEncoder.position(latitude: 47.99999, longitude: 8.99999, symbolTable: "/", symbolCode: ">"),
                       "=4800.00N/00900.00E>")
        XCTAssertEqual(APRSEncoder.position(latitude: 90, longitude: 180, symbolTable: "/", symbolCode: ">"),
                       "=9000.00N/18000.00E>")
        XCTAssertEqual(APRSEncoder.position(latitude: 47.5, longitude: 9.25, symbolTable: "/", symbolCode: ">",
                                            altitudeFeet: -42),
                       "=4730.00N/00915.00E>/A=-00042")
    }

    func testPositionAmbiguityRoundTrip() throws {
        let expected = ["=4733.67N/00917.60E-", "=4733.6 N/00917.6 E-", "=4733.  N/00917.  E-",
                        "=473 .  N/0091 .  E-", "=47  .  N/009  .  E-"]
        for (ambiguity, text) in expected.enumerated() {
            let payload = try XCTUnwrap(APRSEncoder.position(latitude: 47.5612, longitude: 9.2934, ambiguity: ambiguity,
                                                             symbolTable: "/", symbolCode: "-"))
            XCTAssertEqual(payload, text)
            guard case .position(let report) = try APRSParser.parse("N0CALL>APZHMT:" + payload).content else {
                return XCTFail("Keine Position: \(payload)")
            }
            XCTAssertEqual(report.ambiguity, ambiguity)
        }
    }

    func testPositionRejectsBadInput() {
        func position(_ lat: Double, _ lon: Double, table: Character = "/", code: Character = "-", amb: Int = 0) -> String? {
            APRSEncoder.position(latitude: lat, longitude: lon, ambiguity: amb, symbolTable: table, symbolCode: code)
        }
        XCTAssertNil(position(91, 0))
        XCTAssertNil(position(0, 181))
        XCTAssertNil(position(.nan, 0))
        XCTAssertNil(position(0, 0, table: "a"))
        XCTAssertNil(position(0, 0, code: " "))
        XCTAssertNil(position(0, 0, amb: 5))
    }

    func testCommentIsSanitizedAndCapped() throws {
        let payload = try XCTUnwrap(APRSEncoder.position(latitude: 47.5, longitude: 9.25, symbolTable: "/", symbolCode: "-",
                                                         comment: "Grüsse\r\nN0CALL>APRS:>x " + String(repeating: "z", count: 80)))
        XCTAssertFalse(payload.contains("\n"))
        XCTAssertFalse(payload.contains("\r"))
        XCTAssertTrue(payload.hasPrefix("=4730.00N/00915.00E-Gr?sse  N0CALL>APRS:>x zz"))
        XCTAssertEqual(payload.count, 20 + APRSEncoder.maxCommentLength)
    }

    // MARK: - Messages

    func testMessageRoundTrip() throws {
        let payload = try XCTUnwrap(APRSEncoder.message(to: "n0other-9", text: "Hallo: wie geht's?", messageID: "42"))
        XCTAssertEqual(payload, ":N0OTHER-9:Hallo: wie geht's?{42")
        guard case .message(let message) = try APRSParser.parse("N0CALL>APZHMT:" + payload).content else {
            return XCTFail("Keine Message")
        }
        XCTAssertEqual(message, APRSMessage(addressee: "N0OTHER-9", kind: .text, text: "Hallo: wie geht's?", messageID: "42"))
        XCTAssertEqual(APRSEncoder.message(to: "W1AW", text: "ohne Nummer", messageID: nil), ":W1AW     :ohne Nummer")
    }

    func testMessageLimitsAndReservedCharacters() {
        XCTAssertNotNil(APRSEncoder.message(to: "N0OTHER", text: String(repeating: "a", count: 67), messageID: "1"))
        XCTAssertNil(APRSEncoder.message(to: "N0OTHER", text: String(repeating: "a", count: 68), messageID: "1"))
        XCTAssertNil(APRSEncoder.message(to: "N0OTHER", text: "   ", messageID: "1"))
        XCTAssertNil(APRSEncoder.message(to: "", text: "x", messageID: "1"))
        XCTAssertNil(APRSEncoder.message(to: "ZULANGERNAME", text: "x", messageID: "1"))
        XCTAssertNil(APRSEncoder.message(to: "N0:THER", text: "x", messageID: "1"))
        XCTAssertNil(APRSEncoder.message(to: "N0OTHER", text: "x", messageID: "123456"))
        XCTAssertNil(APRSEncoder.message(to: "N0OTHER", text: "x", messageID: "1}2"))
        XCTAssertEqual(APRSEncoder.message(to: "N0OTHER", text: "a{b|c~d grün", messageID: "7"),
                       ":N0OTHER  :a?b?c?d gr?n{7")
        XCTAssertEqual(APRSEncoder.messageText("  Zeile\nzwei  "), "Zeile zwei")
    }

    func testAckRoundTrip() throws {
        let payload = try XCTUnwrap(APRSEncoder.ack(to: "N0OTHER", messageID: "AB1"))
        XCTAssertEqual(payload, ":N0OTHER  :ackAB1")
        guard case .message(let message) = try APRSParser.parse("N0CALL>APZHMT:" + payload).content else {
            return XCTFail("Kein Ack")
        }
        XCTAssertEqual(message.kind, .ack)
        XCTAssertEqual(message.messageID, "AB1")
        XCTAssertNil(APRSEncoder.ack(to: "N0OTHER", messageID: ""))
    }

    // MARK: - Objekte

    func testObjectRoundTripAndKill() throws {
        let time = Date(timeIntervalSince1970: 1_795_304_700)   // 2026-11-21 23:45 UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.day, .hour, .minute], from: time)
        let stamp = String(format: "%02d%02d%02dz", parts.day!, parts.hour!, parts.minute!)

        let live = try XCTUnwrap(APRSEncoder.object(name: "HB9XYZ-FD", isLive: true, time: time,
                                                    latitude: 47.5, longitude: 9.25,
                                                    symbolTable: "/", symbolCode: ";", comment: "Fieldday 145.500"))
        XCTAssertEqual(live, ";HB9XYZ-FD*\(stamp)4730.00N/00915.00E;Fieldday 145.500")
        guard case .object(let object) = try APRSParser.parse("N0CALL>APZHMT:" + live).content else {
            return XCTFail("Kein Objekt")
        }
        XCTAssertEqual(object.name, "HB9XYZ-FD")
        XCTAssertTrue(object.isLive)
        XCTAssertEqual(object.position.comment, "Fieldday 145.500")

        let killed = try XCTUnwrap(APRSEncoder.object(name: "HB9XYZ-FD", isLive: false, time: time,
                                                      latitude: 47.5, longitude: 9.25,
                                                      symbolTable: "/", symbolCode: ";"))
        XCTAssertEqual(killed, ";HB9XYZ-FD_\(stamp)4730.00N/00915.00E;")
        XCTAssertNil(APRSEncoder.object(name: "AB", isLive: true, time: time, latitude: 0, longitude: 0,
                                        symbolTable: "/", symbolCode: ";"))
        // Zu lange Namen werden auf neun Zeichen gekürzt, nicht abgelehnt.
        XCTAssertEqual(APRSEncoder.object(name: "ZULANGERNAME", isLive: true, time: time, latitude: 0, longitude: 0,
                                          symbolTable: "/", symbolCode: ";")?.prefix(11), ";ZULANGERN*")
    }
}
