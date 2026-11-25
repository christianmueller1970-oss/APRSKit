import XCTest
@testable import APRSKit

/// Status, Messages, Objekte, Items und Third-Party.
final class APRSContentTests: XCTestCase {

    private func content(_ payload: String) throws -> APRSContent {
        try APRSParser.parse("N0CALL>APRS:" + payload).content
    }

    // MARK: - Status

    func testStatus() throws {
        XCTAssertEqual(try content(">Net Control Center"),
                       .status(APRSStatusReport(timestamp: nil, text: "Net Control Center")))
        XCTAssertEqual(try content(">092345zNet Control Center"),
                       .status(APRSStatusReport(
                        timestamp: .dayHourMinute(day: 9, hour: 23, minute: 45, isUTC: true),
                        text: "Net Control Center")))
        XCTAssertEqual(try content(">"), .status(APRSStatusReport(timestamp: nil, text: "")))
        // Sieht nur aus wie ein Zeitstempel: bleibt Text.
        XCTAssertEqual(try content(">999999zText"),
                       .status(APRSStatusReport(timestamp: nil, text: "999999zText")))
    }

    // MARK: - Messages

    private func message(_ payload: String, file: StaticString = #filePath, line: UInt = #line) throws -> APRSMessage {
        guard case .message(let message) = try content(payload) else {
            XCTFail("Keine Message: \(payload)", file: file, line: line)
            throw APRSParseError.empty
        }
        return message
    }

    func testMessageWithID() throws {
        let m = try message(":N0OTHER  :Testing{003")
        XCTAssertEqual(m, APRSMessage(addressee: "N0OTHER", kind: .text, text: "Testing", messageID: "003"))
        XCTAssertFalse(m.isBulletin)
    }

    func testMessageWithoutID() throws {
        let m = try message(":N0OTHER-9:Hallo: wie geht's {schon gut}")
        XCTAssertEqual(m.addressee, "N0OTHER-9")
        XCTAssertEqual(m.text, "Hallo: wie geht's {schon gut}")
        XCTAssertNil(m.messageID)
    }

    func testAckAndReject() throws {
        XCTAssertEqual(try message(":N0OTHER  :ack003"),
                       APRSMessage(addressee: "N0OTHER", kind: .ack, text: "", messageID: "003"))
        XCTAssertEqual(try message(":N0OTHER  :rejAB1"),
                       APRSMessage(addressee: "N0OTHER", kind: .reject, text: "", messageID: "AB1"))
        // Kein gültiges Ack: bleibt eine Textnachricht.
        XCTAssertEqual(try message(":N0OTHER  :ack").kind, .text)
        XCTAssertEqual(try message(":N0OTHER  :acknowledged, danke").text, "acknowledged, danke")
    }

    func testReplyAck() throws {
        let m = try message(":N0OTHER  :Antwort{AB}CD")
        XCTAssertEqual(m.text, "Antwort")
        XCTAssertEqual(m.messageID, "AB")
        XCTAssertEqual(m.replyAckID, "CD")
        let open = try message(":N0OTHER  :Frage{AB}")
        XCTAssertEqual(open.messageID, "AB")
        XCTAssertNil(open.replyAckID)
        XCTAssertEqual(try message(":N0OTHER  :ackAB}CD").messageID, "AB")
    }

    func testBulletin() throws {
        let m = try message(":BLN3     :Snow expected in Tampa RSN")
        XCTAssertTrue(m.isBulletin)
        XCTAssertEqual(m.addressee, "BLN3")
    }

    func testInvalidMessagesStayUnparsed() throws {
        for payload in [":N0OTHER :zu kurz", ":N0OTHER", ":         :leer", ":"] {
            XCTAssertEqual(try content(payload), .unparsed, payload)
        }
    }

    // MARK: - Objekte und Items

    func testLiveObject() throws {
        guard case .object(let object) = try content(";LEADER   *092345z4903.50N/07201.75W>088/036") else {
            return XCTFail("Kein Objekt")
        }
        XCTAssertEqual(object.name, "LEADER")
        XCTAssertTrue(object.isLive)
        XCTAssertEqual(object.position.timestamp, .dayHourMinute(day: 9, hour: 23, minute: 45, isUTC: true))
        XCTAssertEqual(object.position.latitude, 49 + 3.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(object.position.course, 88)
        XCTAssertEqual(object.position.speedKnots, 36)
    }

    func testKilledObjectAndCompressedObject() throws {
        guard case .object(let killed) = try content(";LEADER   _092345z4903.50N/07201.75W>") else {
            return XCTFail("Kein Objekt")
        }
        XCTAssertFalse(killed.isLive)
        guard case .object(let compressed) = try content(";HB9 FD   *092345z/5L!!<*e7>7P[Fieldday") else {
            return XCTFail("Kein Objekt")
        }
        XCTAssertEqual(compressed.name, "HB9 FD")
        XCTAssertEqual(compressed.position.latitude, 49.5, accuracy: 1e-4)
        XCTAssertEqual(compressed.position.comment, "Fieldday")
    }

    func testItems() throws {
        guard case .item(let live) = try content(")AID #2!4903.50N/07201.75WA") else {
            return XCTFail("Kein Item")
        }
        XCTAssertEqual(live.name, "AID #2")
        XCTAssertTrue(live.isLive)
        XCTAssertEqual(live.position.symbolCode, "A")
        guard case .item(let killed) = try content(")AID #2_4903.50N/07201.75WA") else {
            return XCTFail("Kein Item")
        }
        XCTAssertFalse(killed.isLive)
    }

    func testInvalidObjectsAndItemsStayUnparsed() throws {
        let payloads = [
            ";LEADER   x092345z4903.50N/07201.75W>",   // weder * noch _
            ";LEADER   *092345z4903.50N",              // Position abgeschnitten
            ";         *092345z4903.50N/07201.75W>",   // leerer Name
            ";LEADER",
            ")AB!4903.50N/07201.75WA",                 // Name zu kurz
            ")ABCDEFGHIJ!4903.50N/07201.75WA",         // Name zu lang
            ")AID #2!4903.50N",
            ")"
        ]
        for payload in payloads {
            XCTAssertEqual(try content(payload), .unparsed, payload)
        }
    }

    // MARK: - Third-Party

    func testThirdPartyUnwrapsInnerPacket() throws {
        guard case .thirdParty(let inner) = try content("}N0INNER>APRS,TCPIP,N0GATE*::N0OTHER  :Hallo{7") else {
            return XCTFail("Kein Third-Party-Paket")
        }
        XCTAssertEqual(inner.source, "N0INNER")
        XCTAssertEqual(inner.path, [APRSPathElement(name: "TCPIP"), APRSPathElement(name: "N0GATE", isUsed: true)])
        XCTAssertEqual(inner.content, .message(APRSMessage(addressee: "N0OTHER", kind: .text,
                                                           text: "Hallo", messageID: "7")))
    }

    func testThirdPartyDepthIsLimited() throws {
        guard case .thirdParty(let inner) = try content("}N0A>APRS:}N0B>APRS:>tief") else {
            return XCTFail("Kein Third-Party-Paket")
        }
        XCTAssertEqual(inner.content, .unparsed)
        XCTAssertEqual(inner.payloadText, "}N0B>APRS:>tief")
        XCTAssertEqual(try content("}kein Kopf"), .unparsed)
    }

    // MARK: - Robustheit

    func testTruncatedAndCorruptedLinesNeverCrash() {
        let lines = [
            "N0CALL>APRS:>092345zNet Control Center",
            "N0CALL>APRS::N0OTHER  :Antwort{AB}CD",
            "N0CALL>APRS::N0OTHER  :ack003",
            "N0CALL>APRS:;LEADER   *092345z4903.50N/07201.75W>088/036",
            "N0CALL>APRS:)AID #2!4903.50N/07201.75WA",
            "N0CALL>APRS:}N0INNER>APRS,TCPIP,N0GATE*::N0OTHER  :Hallo{7"
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
