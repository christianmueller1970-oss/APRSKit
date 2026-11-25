import XCTest
@testable import APRSKit

final class APRSMessageCenterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = "N0CALL-7"

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func message(_ payload: String, file: StaticString = #filePath, line: UInt = #line) -> APRSMessage {
        guard let packet = try? APRSParser.parse("N0X>APRS:" + payload),
              case .message(let message) = packet.content else {
            XCTFail("Keine Message: \(payload)", file: file, line: line)
            return APRSMessage(addressee: "", kind: .text, text: "", messageID: nil)
        }
        return message
    }

    // MARK: - Senden und Wiederholen

    func testComposeNumbersAndSanitizes() {
        var center = APRSMessageCenter()
        XCTAssertEqual(center.compose(to: " n0other ", text: "Hallo\nWelt", now: t0), ":N0OTHER  :Hallo Welt{1")
        XCTAssertEqual(center.compose(to: "N0OTHER", text: "zweite", now: t0), ":N0OTHER  :zweite{2")
        XCTAssertNil(center.compose(to: "N0OTHER", text: "   ", now: t0))
        XCTAssertNil(center.compose(to: "", text: "x", now: t0))
        XCTAssertNil(center.compose(to: "N0OTHER", text: String(repeating: "a", count: 68), now: t0))
        // Abgelehnte Eingaben verbrauchen keine Nummer.
        XCTAssertEqual(center.compose(to: "N0OTHER", text: "dritte", now: t0), ":N0OTHER  :dritte{3")
        XCTAssertEqual(center.outgoing.map(\.state), [.pending, .pending, .pending])
        XCTAssertEqual(center.outgoing.first?.attempts, 1)
    }

    func testRetryScheduleThenUnconfirmed() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0)
        var sends: [TimeInterval] = []
        var second: TimeInterval = 0
        while second <= 1_000 {
            if !center.due(now: at(second)).isEmpty { sends.append(second) }
            second += 1
        }
        // Versuche bei 0 (compose), +45, +60, +120, +240; 480 s nach dem letzten: unbestätigt.
        XCTAssertEqual(sends, [45, 105, 225, 465])
        // Kein Abstand unter 31 s: sonst verwirft APRS-IS die Wiederholung als Duplikat.
        XCTAssertTrue(APRSMessageCenter.retryDelays.allSatisfy { $0 > 30 })
        XCTAssertEqual(center.outgoing.first?.attempts, 5)
        XCTAssertEqual(center.outgoing.first?.state, .unconfirmed)
        XCTAssertEqual(center.due(now: at(5_000)), [])
    }

    func testRetryPayloadKeepsNumberAndText() {
        var center = APRSMessageCenter()
        let first = center.compose(to: "N0OTHER", text: "Test", now: t0)
        XCTAssertEqual(center.due(now: at(44)), [])
        XCTAssertEqual(center.due(now: at(45)), [first])
        XCTAssertEqual(center.due(now: at(46)), [])
    }

    func testAckStopsRetries() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0)
        let result = center.receive(message(":N0CALL-7 :ack1"), from: "n0other", myCall: me, now: at(10))
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.payloads, [])
        XCTAssertEqual(center.outgoing.first?.state, .acknowledged)
        XCTAssertEqual(center.due(now: at(1_000)), [])
    }

    func testAckMustMatchStationNumberAndAddressee() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0)
        XCTAssertFalse(center.receive(message(":N0CALL-7 :ack2"), from: "N0OTHER", myCall: me, now: t0).changed)
        XCTAssertFalse(center.receive(message(":N0CALL-7 :ack1"), from: "N0THIRD", myCall: me, now: t0).changed)
        XCTAssertFalse(center.receive(message(":N0CALL   :ack1"), from: "N0OTHER", myCall: me, now: t0).changed)
        XCTAssertFalse(center.receive(message(":N0CALL-9 :ack1"), from: "N0OTHER", myCall: me, now: t0).changed)
        XCTAssertEqual(center.outgoing.first?.state, .pending)
    }

    func testRejectAndManualResend() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0)
        let id = center.outgoing[0].id
        XCTAssertNil(center.resend(id, now: t0))                       // wartend: kein doppeltes Senden
        _ = center.receive(message(":N0CALL-7 :rej1"), from: "N0OTHER", myCall: me, now: at(5))
        XCTAssertEqual(center.outgoing[0].state, .rejected)
        XCTAssertEqual(center.resend(id, now: at(100)), ":N0OTHER  :Test{1")
        XCTAssertEqual(center.outgoing[0].state, .pending)
        XCTAssertEqual(center.outgoing[0].attempts, 1)
        XCTAssertEqual(center.due(now: at(144)), [])
        XCTAssertEqual(center.due(now: at(145)).count, 1)
        XCTAssertNil(center.resend(UUID(), now: t0))
    }

    func testLateAckSettlesUnconfirmedMessage() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0)
        center.stopRetrying()
        XCTAssertEqual(center.outgoing[0].state, .unconfirmed)
        XCTAssertTrue(center.receive(message(":N0CALL-7 :ack1"), from: "N0OTHER", myCall: me, now: at(900)).changed)
        XCTAssertEqual(center.outgoing[0].state, .acknowledged)
    }

    // MARK: - Empfangen

    func testIncomingIsAckedAndShownOnce() {
        var center = APRSMessageCenter()
        let incoming = message(":N0CALL-7 :Hallo{42")
        let first = center.receive(incoming, from: "N0OTHER", myCall: me, now: t0)
        XCTAssertEqual(first.payloads, [":N0OTHER  :ack42"])
        XCTAssertEqual(first.newMessage?.text, "Hallo")
        XCTAssertEqual(first.newMessage?.from, "N0OTHER")
        // Wiederholung der Gegenstation (unser Ack ging verloren): erneut bestätigen, nicht erneut zeigen.
        let second = center.receive(incoming, from: "N0OTHER", myCall: me, now: at(30))
        XCTAssertEqual(second.payloads, [":N0OTHER  :ack42"])
        XCTAssertNil(second.newMessage)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(center.incoming.count, 1)
        // Gleiche Nummer, anderer Text: neue Message.
        let other = center.receive(message(":N0CALL-7 :Neu{42"), from: "N0OTHER", myCall: me, now: at(60))
        XCTAssertNotNil(other.newMessage)
        // Gleiche Nummer und gleicher Text nach mehr als einem Tag: neue Message.
        let later = center.receive(incoming, from: "N0OTHER", myCall: me, now: at(25 * 3600))
        XCTAssertNotNil(later.newMessage)
        XCTAssertEqual(center.incoming.count, 3)
    }

    func testIncomingWithoutNumberIsNotAcked() {
        var center = APRSMessageCenter()
        let result = center.receive(message(":N0CALL-7 :ohne Nummer"), from: "N0OTHER", myCall: me, now: t0)
        XCTAssertEqual(result.payloads, [])
        XCTAssertEqual(result.newMessage?.messageID, nil)
        XCTAssertEqual(center.incoming.count, 1)
    }

    func testForeignMessagesAndOwnEchoAreIgnored() {
        var center = APRSMessageCenter()
        for (payload, from) in [(":N0THIRD  :nicht für mich{1", "N0OTHER"), (":N0CALL   :andere SSID{1", "N0OTHER"),
                                (":N0CALL-7 :Echo{1", "N0CALL-7")] {
            let result = center.receive(message(payload), from: from, myCall: me, now: t0)
            XCTAssertEqual(result, APRSMessageCenter.ReceiveResult(), payload)
        }
        XCTAssertEqual(center.receive(message(":N0CALL-7 :x{1"), from: "N0OTHER", myCall: "", now: t0),
                       APRSMessageCenter.ReceiveResult())
        XCTAssertEqual(center.incoming.count, 0)
    }

    func testReplyAckSettlesOutgoingAndAcksIncoming() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Frage", now: t0)
        let result = center.receive(message(":N0CALL-7 :Antwort{AB}1"), from: "N0OTHER", myCall: me, now: at(20))
        XCTAssertEqual(center.outgoing[0].state, .acknowledged)
        XCTAssertEqual(result.payloads, [":N0OTHER  :ackAB"])
        XCTAssertEqual(result.newMessage?.text, "Antwort")
    }

    func testBulletins() {
        var center = APRSMessageCenter()
        let first = center.receive(message(":BLN1     :Fieldday am Samstag"), from: "N0CLUB", myCall: me, now: t0)
        XCTAssertEqual(first.newBulletin?.name, "BLN1")
        XCTAssertEqual(first.payloads, [])
        // Gleicher Text erneut: kein neuer Hinweis.
        XCTAssertNil(center.receive(message(":BLN1     :Fieldday am Samstag"), from: "N0CLUB", myCall: me, now: at(600)).newBulletin)
        // Geänderter Text ersetzt den alten.
        XCTAssertEqual(center.receive(message(":BLN1     :Fieldday verschoben"), from: "N0CLUB", myCall: me, now: at(900)).newBulletin?.text,
                       "Fieldday verschoben")
        _ = center.receive(message(":BLN2     :zweites"), from: "N0CLUB", myCall: me, now: at(901))
        XCTAssertEqual(center.bulletins.count, 2)
        XCTAssertEqual(center.incoming.count, 0)
        center.removeBulletins()
        XCTAssertEqual(center.bulletins.count, 0)
    }

    // MARK: - Verlauf

    func testRemoveConversationAndCodableRoundTrip() throws {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "eins", now: t0)
        _ = center.compose(to: "N0THIRD", text: "zwei", now: t0)
        _ = center.receive(message(":N0CALL-7 :drei{9"), from: "N0OTHER", myCall: me, now: t0)
        let data = try JSONEncoder().encode(center)
        var restored = try JSONDecoder().decode(APRSMessageCenter.self, from: data)
        XCTAssertEqual(restored, center)
        // Die Laufnummer zählt nach dem Laden weiter.
        XCTAssertEqual(restored.compose(to: "N0OTHER", text: "vier", now: t0), ":N0OTHER  :vier{3")
        restored.removeConversation(with: "n0other")
        XCTAssertEqual(restored.outgoing.map(\.to), ["N0THIRD"])
        XCTAssertEqual(restored.incoming.count, 0)
    }

    func testNumbersWrapAfter99999() throws {
        var center = APRSMessageCenter()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(center)) as! [String: Any]
        var patched = json
        patched["nextNumber"] = 99_999
        center = try JSONDecoder().decode(APRSMessageCenter.self,
                                          from: JSONSerialization.data(withJSONObject: patched))
        XCTAssertEqual(center.compose(to: "N0OTHER", text: "a", now: t0), ":N0OTHER  :a{99999")
        XCTAssertEqual(center.compose(to: "N0OTHER", text: "b", now: t0), ":N0OTHER  :b{1")
    }

    func testHistoryIsCappedButKeepsPendingMessages() {
        var center = APRSMessageCenter()
        for index in 0..<(APRSMessageCenter.maxMessages + 20) {
            _ = center.receive(message(":N0CALL-7 :Nr \(index){\(index % 90_000)"), from: "N0OTHER", myCall: me,
                               now: at(Double(index)))
        }
        XCTAssertEqual(center.incoming.count, APRSMessageCenter.maxMessages)
        XCTAssertEqual(center.incoming.first?.text, "Nr 20")

        var sender = APRSMessageCenter()
        _ = sender.compose(to: "N0OTHER", text: "wartet", now: t0)
        for index in 0..<(APRSMessageCenter.maxMessages + 5) {
            _ = sender.compose(to: "N0OTHER", text: "x\(index)", now: t0)
            sender.stopRetrying()
        }
        _ = sender.compose(to: "N0OTHER", text: "neu", now: t0)
        XCTAssertLessThanOrEqual(sender.outgoing.count, APRSMessageCenter.maxMessages)
        XCTAssertEqual(sender.outgoing.last?.state, .pending)
    }

    // MARK: - Weg (Internet / Funk)

    func testRetriesStayOnTheirTransport() {
        var center = APRSMessageCenter()
        let viaNet = center.compose(to: "N0OTHER", text: "Netz", now: t0)
        let viaRadio = center.compose(to: "N0OTHER", text: "Funk", now: t0, transport: .radio)
        XCTAssertEqual(center.outgoing.map(\.route), [.internet, .radio])
        // Jeder Weg liefert nur seine eigenen Wiederholungen.
        XCTAssertEqual(center.due(now: at(45), on: .internet), [viaNet])
        XCTAssertEqual(center.due(now: at(45), on: .radio), [viaRadio])
        XCTAssertEqual(center.due(now: at(46), on: .radio), [])
    }

    func testStopRetryingOnOneTransportLeavesTheOther() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Netz", now: t0)
        _ = center.compose(to: "N0OTHER", text: "Funk", now: t0, transport: .radio)
        center.stopRetrying(on: .internet)
        XCTAssertEqual(center.outgoing.map(\.state), [.unconfirmed, .pending])
        center.stopRetrying()
        XCTAssertEqual(center.outgoing.map(\.state), [.unconfirmed, .unconfirmed])
    }

    func testResendCanSwitchTransport() {
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0)
        center.stopRetrying()
        let id = center.outgoing[0].id
        XCTAssertEqual(center.resend(id, now: at(100), transport: .radio), ":N0OTHER  :Test{1")
        XCTAssertEqual(center.outgoing[0].route, .radio)
        XCTAssertEqual(center.due(now: at(145), on: .internet), [])
        XCTAssertEqual(center.due(now: at(145), on: .radio).count, 1)
    }

    func testAckSettlesRegardlessOfTransport() {
        // Gesendet über Funk, Bestätigung kommt über ein iGate aus dem Internet.
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "Test", now: t0, transport: .radio)
        let result = center.receive(message(":N0CALL-7 :ack1"), from: "N0OTHER", myCall: me, now: at(10),
                                    transport: .internet)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(center.outgoing[0].state, .acknowledged)
    }

    func testIncomingRemembersTransportOfFirstReception() {
        var center = APRSMessageCenter()
        let incoming = message(":N0CALL-7 :Hallo{7")
        let first = center.receive(incoming, from: "N0OTHER", myCall: me, now: t0, transport: .radio)
        XCTAssertEqual(first.newMessage?.transport, .radio)
        // Dieselbe Message kurz danach über das Internet: Duplikat, aber wieder bestätigt.
        let second = center.receive(incoming, from: "N0OTHER", myCall: me, now: at(3), transport: .internet)
        XCTAssertNil(second.newMessage)
        XCTAssertEqual(second.payloads, [":N0OTHER  :ack7"])
        XCTAssertEqual(center.incoming.map(\.transport), [.radio])
    }

    func testHistoryWithoutTransportDecodesAsInternet() throws {
        // Verlauf aus Stufe 2 (ohne Feld «transport»).
        var center = APRSMessageCenter()
        _ = center.compose(to: "N0OTHER", text: "alt", now: t0)
        _ = center.receive(message(":N0CALL-7 :alt{3"), from: "N0OTHER", myCall: me, now: t0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(center)) as! [String: Any]
        for key in ["outgoing", "incoming"] {
            json[key] = (json[key] as! [[String: Any]]).map { entry in
                var copy = entry
                copy.removeValue(forKey: "transport")
                return copy
            }
        }
        let restored = try JSONDecoder().decode(APRSMessageCenter.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.outgoing[0].transport)
        XCTAssertEqual(restored.outgoing[0].route, .internet)
        XCTAssertNil(restored.incoming[0].transport)
    }
}
