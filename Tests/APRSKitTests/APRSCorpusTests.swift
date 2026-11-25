import XCTest
@testable import APRSKit

/// Korpus realer Pakete aus einem APRS-IS-Mitschnitt (`Resources/corpus.txt`,
/// eine Zeile je Paket, Bytes unverändert). `corpus-expected.tsv` hält je
/// Zeile fest, was der Parser daraus liest; jede Abweichung ist ein Befund.
///
/// Soll-Datei neu schreiben (nur nach geprüfter Parser-Änderung):
/// `APRS_UPDATE_EXPECTED=1 swift test --filter APRSCorpusTests`
final class APRSCorpusTests: XCTestCase {

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Resources")

    private func corpusLines() throws -> [[UInt8]] {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("corpus.txt"))
        return data.split(separator: UInt8(ascii: "\n")).map(Array.init)
    }

    // MARK: - Zusammenfassung je Paket

    private func number(_ value: Double?, _ digits: Int) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? "-"
    }

    private func describe(_ p: APRSPositionReport) -> String {
        var parts = [
            "lat=" + number(p.latitude, 5), "lon=" + number(p.longitude, 5),
            "amb=\(p.ambiguity)", "sym=\(p.symbolTable)\(p.symbolCode)",
            "crs=" + (p.course.map(String.init) ?? "-"), "spd=" + number(p.speedKnots, 1),
            "alt=" + number(p.altitudeFeet, 0), "msg=\(p.supportsMessaging ? 1 : 0)"
        ]
        if let t = p.timestamp { parts.append("time=\(t)") }
        if let r = p.radioRangeMiles { parts.append("rng=" + number(r, 1)) }
        if let g = p.phg {
            parts.append("phg=\(g.powerWatts)/\(g.heightFeet)/\(g.gainDb)/\(g.directivityDegrees.map(String.init) ?? "-")")
        }
        if let m = p.micEStatus { parts.append("mice=\(m)") }
        if let w = p.weather { parts.append(describe(w)) }
        parts.append("comment=\(p.comment)")
        return parts.joined(separator: " ")
    }

    private func describe(_ w: APRSWeather) -> String {
        func v(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        return "wx=dir:\(v(w.windDirectionDegrees)),spd:\(v(w.windSpeedMph)),gust:\(v(w.gustMph))"
            + ",t:\(v(w.temperatureFahrenheit)),r:\(v(w.rainLastHour)),p:\(v(w.rainLast24Hours))"
            + ",P:\(v(w.rainSinceMidnight)),h:\(v(w.humidityPercent)),b:\(v(w.pressureTenthsMillibar))"
            + ",L:\(v(w.luminosity)),snow:\(number(w.snowLast24Hours, 1))"
    }

    private func describe(_ content: APRSContent) -> String {
        switch content {
        case .position(let p): return "position " + describe(p)
        case .object(let o): return "object name=\(o.name) live=\(o.isLive ? 1 : 0) " + describe(o.position)
        case .item(let i): return "item name=\(i.name) live=\(i.isLive ? 1 : 0) " + describe(i.position)
        case .status(let s): return "status time=\(s.timestamp.map { "\($0)" } ?? "-") text=\(s.text)"
        case .message(let m):
            return "message to=\(m.addressee) kind=\(m.kind) id=\(m.messageID ?? "-") "
                + "reply=\(m.replyAckID ?? "-") text=\(m.text)"
        case .weather(let w):
            return "weather time=\(w.timestamp.map { "\($0)" } ?? "-") " + describe(w.weather)
                + " comment=\(w.comment)"
        case .telemetry(let t):
            return "telemetry seq=\(t.sequence) analog=\(t.analog.map { number($0, 2) }.joined(separator: ","))"
                + " digital=\(t.digital.map { $0 ? "1" : "0" }.joined()) comment=\(t.comment)"
        case .thirdParty(let inner):
            return "thirdparty \(inner.source)>\(inner.destination) " + describe(inner.content)
        case .unparsed: return "unparsed"
        }
    }

    private func summary(of line: [UInt8]) -> String {
        do {
            let packet = try APRSParser.parse(line)
            let path = packet.path.map { $0.name + ($0.isUsed ? "*" : "") }.joined(separator: ",")
            let text = "\(packet.source)\t\(packet.destination)\t\(path)\t" + describe(packet.content)
            // Steuerzeichen würden das Zeilenformat der Soll-Datei brechen.
            return String(text.unicodeScalars.map { $0.value < 0x20 && $0 != "\t" ? "?" : Character($0) })
        } catch {
            return "FEHLER \(error)"
        }
    }

    // MARK: - Tests

    func testCorpusMatchesExpected() throws {
        let actual = try corpusLines().map(summary(of:))
        let url = Self.resources.appendingPathComponent("corpus-expected.tsv")
        if ProcessInfo.processInfo.environment["APRS_UPDATE_EXPECTED"] == "1" {
            try (actual.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(actual.count, expected.count, "Zeilenzahl Korpus und Soll-Datei")
        for (index, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
            XCTFail("Zeile \(index + 1):\n  ist:  \(pair.0)\n  soll: \(pair.1)")
        }
    }

    /// Abnahmekriterium Stufe 1: mindestens 200 reale Pakete, alle Typen vertreten.
    /// Im Mitschnitt vom 2026-11-21 fehlen noch Third-Party-Pakete und
    /// positionslose Wetterberichte; sie kommen mit einem späteren Mitschnitt dazu
    /// und werden dann hier Pflicht (siehe Plan, Stand M1).
    func testCorpusCoverage() throws {
        var counts: [String: Int] = [:]
        var failures = 0
        let lines = try corpusLines()
        for line in lines {
            guard let packet = try? APRSParser.parse(line) else { failures += 1; continue }
            var content = packet.content
            if case .thirdParty(let inner) = content {
                counts["thirdParty", default: 0] += 1
                content = inner.content
            }
            let kind: String
            switch content {
            case .position(let p):
                kind = p.micEStatus != nil || [UInt8(ascii: "`"), UInt8(ascii: "'")].contains(packet.dataTypeIdentifier)
                    ? "micE" : (p.weather != nil ? "weatherPosition" : "position")
            case .object: kind = "object"
            case .item: kind = "item"
            case .status: kind = "status"
            case .message: kind = "message"
            case .weather: kind = "weather"
            case .telemetry: kind = "telemetry"
            case .thirdParty: kind = "thirdParty"
            case .unparsed: kind = "unparsed"
            }
            counts[kind, default: 0] += 1
        }
        print("Korpus: \(lines.count) Pakete, Kopf nicht lesbar: \(failures), \(counts.sorted { $0.key < $1.key })")
        XCTAssertGreaterThanOrEqual(lines.count, 200)
        XCTAssertEqual(failures, 0, "Pakete mit nicht lesbarem Kopf")
        for kind in ["position", "micE", "object", "item", "status", "message",
                     "weatherPosition", "telemetry"] {
            XCTAssertGreaterThan(counts[kind, default: 0], 0, "Typ fehlt im Korpus: \(kind)")
        }
        // Rohpakete sind erlaubt, sollen aber die Ausnahme bleiben.
        XCTAssertLessThan(Double(counts["unparsed", default: 0]), Double(lines.count) * 0.05)
    }

    /// Jedes Korpus-Paket abgeschnitten und verfälscht: nie ein Absturz.
    func testCorpusSurvivesTruncationAndCorruption() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for line in try corpusLines() where !line.isEmpty {
            for _ in 0..<8 {
                _ = try? APRSParser.parse(Array(line.prefix(Int(next() % UInt64(line.count)))))
                var corrupted = line
                for _ in 0..<(1 + Int(next() % 3)) {
                    corrupted[Int(next() % UInt64(line.count))] = UInt8(truncatingIfNeeded: next())
                }
                _ = try? APRSParser.parse(corrupted)
            }
        }
    }
}
