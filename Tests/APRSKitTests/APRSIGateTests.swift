import XCTest
@testable import APRSKit

/// Jede Regel des iGate einzeln, nach aprs-is.net «IGate Details».
final class APRSIGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = "N0GATE-5"

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func toInternet(_ gate: inout APRSIGate, _ line: String, transmits: Bool = true,
                            at seconds: TimeInterval = 0) throws -> APRSIGate.Decision {
        let bytes = Array(line.utf8)
        return gate.gateToInternet(line: bytes, packet: try APRSParser.parse(bytes), igate: me,
                                   transmitsToRadio: transmits, receivedAt: at(seconds))
    }

    private func text(_ decision: APRSIGate.Decision) -> String? {
        if case .gate(let bytes) = decision { return String(decoding: bytes, as: UTF8.self) }
        return nil
    }

    // MARK: - Funk → Internet

    func testGatesWithUnchangedPathAndQAR() throws {
        var gate = APRSIGate()
        let decision = try toInternet(&gate, "N0CALL-9>APRS,N0DIGI*,WIDE2-1:=4903.50N/07201.75W>Test")
        XCTAssertEqual(text(decision), "N0CALL-9>APRS,N0DIGI*,WIDE2-1,qAR,N0GATE-5:=4903.50N/07201.75W>Test")
    }

    func testReceiveOnlyUsesQAO() throws {
        var gate = APRSIGate()
        let decision = try toInternet(&gate, "N0CALL-9>APRS:>Status", transmits: false)
        XCTAssertEqual(text(decision), "N0CALL-9>APRS,qAO,N0GATE-5:>Status")
    }

    func testPathMarkersAreNotGated() throws {
        for marker in ["TCPIP", "TCPIP*", "TCPXX*", "NOGATE", "RFONLY", "nogate"] {
            var gate = APRSIGate()
            XCTAssertEqual(try toInternet(&gate, "N0CALL-9>APRS,WIDE1-1,\(marker):>Status"), .skip(.pathMarker), marker)
        }
    }

    func testGenericQueryIsNotGated() throws {
        var gate = APRSIGate()
        XCTAssertEqual(try toInternet(&gate, "N0CALL-9>APRS:?APRS?"), .skip(.query))
        // Eine gerichtete Abfrage in einer Message ist eine Message, keine allgemeine Abfrage.
        XCTAssertNotNil(text(try toInternet(&gate, "N0CALL-9>APRS::N0OTHER  :?APRSP")))
    }

    func testThirdPartyFromInternetIsNotGatedBack() throws {
        var gate = APRSIGate()
        let line = "N0OTHER-10>APRS,WIDE1-1:}N0FAR>APRS,TCPIP,N0OTHER-10*::N0CALL-9 :Hallo{1"
        XCTAssertEqual(try toInternet(&gate, line), .skip(.fromInternet))
    }

    func testThirdPartyFromRadioIsUnwrapped() throws {
        var gate = APRSIGate()
        // Ohne TCPIP im inneren Kopf: äusseren Kopf und `}` entfernen.
        let line = "N0RELAY>APRS,WIDE1-1:}N0FAR>APRS,WIDE2-1:>Status"
        XCTAssertEqual(text(try toInternet(&gate, line)), "N0FAR>APRS,WIDE2-1,qAR,N0GATE-5:>Status")
        // NOGATE im äusseren Pfad gilt auch für das eingepackte Paket.
        var other = APRSIGate()
        XCTAssertEqual(try toInternet(&other, "N0RELAY>APRS,NOGATE:}N0FAR>APRS:>Status"), .skip(.pathMarker))
    }

    func testInternetMarkerInOuterPathBlocksWrappedPacket() throws {
        // Codex-Review 21.11.2026: der äussere Pfad trägt den Internet-Vermerk, der innere nicht.
        var gate = APRSIGate()
        XCTAssertEqual(try toInternet(&gate, "N0RELAY>APRS,TCPIP*:}N0FAR>APRS:>Status"), .skip(.pathMarker))
        XCTAssertEqual(try toInternet(&gate, "N0RELAY>APRS,TCPXX*:}N0FAR>APRS:>Status"), .skip(.pathMarker))
    }

    func testOwnPacketsAreNeverGated() throws {
        var gate = APRSIGate()
        XCTAssertEqual(try toInternet(&gate, "n0gate-5>APZHMT,WIDE1-1:>Status"), .skip(.own))
        XCTAssertEqual(try toInternet(&gate, "N0RELAY>APRS:}N0GATE-5>APZHMT:>Status"), .skip(.own))
        // Ohne gültiges iGate-Rufzeichen wird nichts weitergereicht.
        let bytes = Array("N0CALL-9>APRS:>Status".utf8)
        XCTAssertEqual(gate.gateToInternet(line: bytes, packet: try APRSParser.parse(bytes), igate: "",
                                           transmitsToRadio: true, receivedAt: t0), .skip(.own))
    }

    func testDuplicatesWithinWindowAreGatedOnce() throws {
        var gate = APRSIGate()
        XCTAssertNotNil(text(try toInternet(&gate, "N0CALL-9>APRS:>Status")))
        // Dieselben Nutzdaten kurz danach über einen Digipeater: Duplikat.
        XCTAssertEqual(try toInternet(&gate, "N0CALL-9>APRS,N0DIGI*:>Status", at: 5), .skip(.duplicate))
        // Andere Nutzdaten oder andere Quelle: kein Duplikat.
        XCTAssertNotNil(text(try toInternet(&gate, "N0CALL-9>APRS:>Anders", at: 6)))
        XCTAssertNotNil(text(try toInternet(&gate, "N0OTHER>APRS:>Status", at: 7)))
        // Nach Ablauf der Frist, gerechnet gegen den Empfang, wieder erlaubt.
        XCTAssertNotNil(text(try toInternet(&gate, "N0CALL-9>APRS:>Status", at: 31)))
    }

    func testEmbeddedLineBreakIsNotGated() throws {
        var gate = APRSIGate()
        let bytes = Array("N0CALL-9>APRS:>Status".utf8) + [0x0D] + Array("user x pass 1".utf8)
        let packet = APRSPacket(source: "N0CALL-9", destination: "APRS", path: [],
                                payload: Array(bytes.drop(while: { $0 != UInt8(ascii: ":") }).dropFirst()),
                                content: .unparsed)
        XCTAssertEqual(gate.gateToInternet(line: bytes, packet: packet, igate: me, transmitsToRadio: true,
                                           receivedAt: t0), .skip(.malformed))
    }

    // MARK: - Internet → Funk

    /// Stationsspeicher mit einem lokal über Funk gehörten Empfänger.
    private func table(recipientHops: Int = 0, heardAt seconds: TimeInterval = 0) throws -> APRSStationTable {
        var table = APRSStationTable()
        let path = recipientHops == 0 ? "" : "," + (1...recipientHops).map { "N0DIG\($0)*" }.joined(separator: ",")
        table.ingest(try APRSParser.parse("N0CALL-9>APRS\(path):=4903.50N/07201.75W>"),
                     receivedAt: at(seconds), transport: .radio)
        return table
    }

    private func toRadio(_ gate: inout APRSIGate, _ line: String, table: APRSStationTable,
                         at seconds: TimeInterval = 60) throws -> APRSIGate.Decision {
        gate.gateToRadio(try APRSParser.parse(line), igate: me, receivedAt: at(seconds)) {
            table.stations[APRSStationTable.key($0)]
        }
    }

    private let message = "N0FAR>APRS,TCPIP*,qAC,T2TEST::N0CALL-9 :Hallo{1"

    func testMessageToLocalStationIsGatedAsThirdParty() throws {
        var gate = APRSIGate()
        let decision = try toRadio(&gate, message, table: try table())
        // APRS-IS-Pfad und q-Konstrukt entfallen; `TCPIP,<igate>*` ist Pflicht.
        XCTAssertEqual(text(decision), "}N0FAR>APRS,TCPIP,N0GATE-5*::N0CALL-9 :Hallo{1")
    }

    func testAckIsGatedLikeAMessage() throws {
        var gate = APRSIGate()
        let ack = "N0FAR>APRS,TCPIP*,qAC,T2TEST::N0CALL-9 :ack7"
        XCTAssertEqual(text(try toRadio(&gate, ack, table: try table())), "}N0FAR>APRS,TCPIP,N0GATE-5*::N0CALL-9 :ack7")
    }

    func testRecipientMustBeHeardLocallyAndRecently() throws {
        var gate = APRSIGate()
        // Nie gehört.
        XCTAssertEqual(try toRadio(&gate, message, table: APRSStationTable()), .skip(.recipientNotLocal))
        // Nur über APRS-IS gehört, nicht vom eigenen Empfänger.
        var netOnly = APRSStationTable()
        netOnly.ingest(try APRSParser.parse("N0CALL-9>APRS,WIDE1-1,qAR,N0OTHER:>x"), receivedAt: t0)
        XCTAssertEqual(try toRadio(&gate, message, table: netOnly), .skip(.recipientNotLocal))
        // Zu lange her: 60 min, gerechnet gegen den Empfang der Message.
        XCTAssertEqual(try toRadio(&gate, message, table: try table(), at: 3_600), .skip(.recipientNotLocal))
        XCTAssertNotNil(text(try toRadio(&gate, message, table: try table(), at: 3_599)))
    }

    func testRecipientBeyondOneDigipeaterIsNotLocal() throws {
        var gate = APRSIGate()
        XCTAssertNotNil(text(try toRadio(&gate, message, table: try table(recipientHops: 1))))
        XCTAssertEqual(try toRadio(&gate, message, table: try table(recipientHops: 2)), .skip(.recipientNotLocal))
    }

    func testRecipientSeenOnInternetIsNotGated() throws {
        var gate = APRSIGate()
        var table = try table()
        // Der Empfänger ist selbst direkt am Internet (TCPIP* im Pfad).
        table.ingest(try APRSParser.parse("N0CALL-9>APRS,TCPIP*,qAC,T2TEST:>online"), receivedAt: at(10))
        XCTAssertEqual(try toRadio(&gate, message, table: table), .skip(.recipientOnInternet))
        // Oder er tritt auf Funk selbst als iGate auf.
        var other = try self.table()
        other.ingest(try APRSParser.parse("N0CALL-9>APRS:}N0X>APRS,TCPIP,N0CALL-9*:>y"),
                     receivedAt: at(10), transport: .radio)
        XCTAssertEqual(try toRadio(&gate, message, table: other), .skip(.recipientOnInternet))
    }

    func testIGateFirstHeardThroughThirdPartyIsRemembered() throws {
        // Codex-Review 21.11.2026: Third-Party-Paket → Funkbake → Nachricht.
        var gate = APRSIGate()
        var table = APRSStationTable()
        table.ingest(try APRSParser.parse("N0CALL-9>APRS:}N0X>APRS,TCPIP,N0CALL-9*:>y"),
                     receivedAt: at(0), transport: .radio)
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastHeardViaInternet, at(0))
        table.ingest(try APRSParser.parse("N0CALL-9>APRS:=4903.50N/07201.75W&"), receivedAt: at(10), transport: .radio)
        XCTAssertEqual(try toRadio(&gate, message, table: table), .skip(.recipientOnInternet))
    }

    func testSenderHeardOnRadioIsNotGated() throws {
        var gate = APRSIGate()
        var table = try table()
        table.ingest(try APRSParser.parse("N0FAR>APRS:=4903.50N/07201.75W-"), receivedAt: at(5), transport: .radio)
        XCTAssertEqual(try toRadio(&gate, message, table: table), .skip(.senderOnRadio))
        // Von einem anderen iGate auf Funk gereichte Pakete des Absenders zählen dabei nicht.
        var relayed = try self.table()
        relayed.ingest(try APRSParser.parse("N0OTHER-10>APRS:}N0FAR>APRS,TCPIP,N0OTHER-10*:>z"),
                       receivedAt: at(5), transport: .radio)
        XCTAssertNotNil(text(try toRadio(&gate, message, table: relayed)))
    }

    func testSenderMarkersBlockGating() throws {
        for marker in ["TCPXX*", "NOGATE", "RFONLY"] {
            var gate = APRSIGate()
            let line = "N0FAR>APRS,\(marker),qAX,T2TEST::N0CALL-9 :Hallo{1"
            XCTAssertEqual(try toRadio(&gate, line, table: try table()), .skip(.pathMarker), marker)
        }
    }

    func testOnlyDirectedMessagesAreEligible() throws {
        var gate = APRSIGate()
        let table = try table()
        XCTAssertEqual(try toRadio(&gate, "N0FAR>APRS,TCPIP*,qAC,T2TEST::BLN1     :Rundmeldung", table: table),
                       .skip(.notEligible))
        XCTAssertEqual(try toRadio(&gate, "N0FAR>APRS,TCPIP*,qAC,T2TEST:>Status", table: table), .skip(.notEligible))
        XCTAssertEqual(try toRadio(&gate, "N0FAR>APRS,TCPIP*,qAC,T2TEST:=4903.50N/07201.75W-", table: table),
                       .skip(.notEligible))
        // An das iGate selbst oder vom iGate selbst: nichts weiterzureichen.
        XCTAssertEqual(try toRadio(&gate, "N0FAR>APRS,TCPIP*,qAC,T2TEST::N0GATE-5 :Hallo{1", table: table), .skip(.own))
        XCTAssertEqual(try toRadio(&gate, "N0GATE-5>APRS,TCPIP*,qAC,T2TEST::N0CALL-9 :Hallo{1", table: table), .skip(.own))
    }

    func testSenderPositionFollowsMessageOncePerSpacing() throws {
        var gate = APRSIGate()
        let table = try table()
        let position = "N0FAR>APRS,TCPIP*,qAC,T2TEST:=4903.50N/07201.75W-Daheim"
        XCTAssertNotNil(text(try toRadio(&gate, message, table: table, at: 60)))
        XCTAssertEqual(text(try toRadio(&gate, position, table: table, at: 90)),
                       "}N0FAR>APRS,TCPIP,N0GATE-5*:=4903.50N/07201.75W-Daheim")
        // Die nächste Position nicht mehr, auch nicht nach einer weiteren Message innert der Frist.
        XCTAssertEqual(try toRadio(&gate, position, table: table, at: 120), .skip(.notEligible))
        XCTAssertNotNil(text(try toRadio(&gate, message, table: table, at: 150)))
        XCTAssertEqual(try toRadio(&gate, position, table: table, at: 180), .skip(.notEligible))
        // Die Position eines Fremden ohne Message geht nie auf Funk.
        XCTAssertEqual(try toRadio(&gate, "N0X>APRS,TCPIP*,qAC,T2TEST:=4903.50N/07201.75W-", table: table, at: 200),
                       .skip(.notEligible))
    }

    func testRateLimitPerMinuteAndPerHour() throws {
        var gate = APRSIGate()
        // Empfänger wird über die ganze Zeit immer wieder gehört.
        func fresh(_ seconds: TimeInterval) throws -> APRSStationTable { try table(heardAt: seconds - 10) }
        for index in 0..<APRSIGate.maxPerMinute {
            XCTAssertNotNil(text(try toRadio(&gate, message, table: try fresh(100), at: 100 + Double(index))), "\(index)")
        }
        XCTAssertEqual(try toRadio(&gate, message, table: try fresh(100), at: 110), .skip(.rateLimited))
        // Nach einer Minute wieder, bis die Stundengrenze greift.
        var sent = APRSIGate.maxPerMinute
        var second = 170.0
        while sent < APRSIGate.maxPerHour {
            XCTAssertNotNil(text(try toRadio(&gate, message, table: try fresh(second), at: second)), "\(sent)")
            sent += 1
            second += 11   // höchstens 6 je Minute
        }
        XCTAssertEqual(try toRadio(&gate, message, table: try fresh(second), at: second), .skip(.rateLimited))
        // Eine Stunde nach den ersten Paketen ist wieder Platz.
        XCTAssertNotNil(text(try toRadio(&gate, message, table: try fresh(3_800), at: 3_800)))
    }

    func testUnprintablePayloadIsNotSentOnRadio() throws {
        var gate = APRSIGate()
        let packet = APRSPacket(source: "N0FAR", destination: "APRS",
                                path: [APRSPathElement(name: "TCPIP", isUsed: true)],
                                payload: Array(":N0CALL-9 :Hal".utf8) + [0x0D] + Array("lo".utf8),
                                content: .message(APRSMessage(addressee: "N0CALL-9", kind: .text, text: "Hallo",
                                                              messageID: nil)))
        let table = try table()
        XCTAssertEqual(gate.gateToRadio(packet, igate: me, receivedAt: at(60)) { table.stations[$0] },
                       .skip(.malformed))
    }

    // MARK: - Stationsspeicher

    func testTableTracksHopsAndInternetPresence() throws {
        var table = APRSStationTable()
        table.ingest(try APRSParser.parse("N0CALL-9>APRS,N0DIG1,N0DIG2*,WIDE2-1:>x"), receivedAt: t0, transport: .radio)
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastRadioHops, 2)
        XCTAssertNil(table.stations["N0CALL-9"]?.lastHeardViaInternet)
        // Über ein fremdes iGate gehört (qAR): das ist Funk, nicht «am Internet».
        table.ingest(try APRSParser.parse("N0CALL-9>APRS,WIDE1-1,qAR,N0OTHER:>x"), receivedAt: at(5))
        XCTAssertNil(table.stations["N0CALL-9"]?.lastHeardViaInternet)
        table.ingest(try APRSParser.parse("N0CALL-9>APRS,TCPIP*,qAC,T2TEST:>x"), receivedAt: at(9))
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastHeardViaInternet, at(9))
        // Eigene Aussendungen übers Internet machen die eigene Station nicht «am Internet gehört».
        table.ingest(try APRSParser.parse("N0GATE-5>APZHMT,TCPIP*:>x"), receivedAt: t0, isOwn: true)
        XCTAssertNil(table.stations["N0GATE-5"]?.lastHeardViaInternet)
    }
}
