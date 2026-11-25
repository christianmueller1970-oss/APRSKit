import XCTest
@testable import AX25Kit

/// Rundlauf über den APRS-Korpus (378 reale Pakete aus APRS-IS): jedes Paket,
/// dessen Kopf sich als AX.25 darstellen lässt, ergibt über Rahmen, HDLC und
/// Audio wieder genau dieselbe Zeile.
final class AX25CorpusTests: XCTestCase {

    private func corpus() throws -> [[UInt8]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../APRSKitTests/Resources/corpus.txt").standardizedFileURL
        return try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).map(Array.init)
    }

    /// Pakete aus APRS-IS tragen das q-Konstrukt und den Servernamen im Pfad.
    /// Was über Funk gesendet würde, ist der Teil davor.
    private func radioForm(_ line: [UInt8]) -> [UInt8] {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return line }
        let header = String(decoding: line[..<colon], as: UTF8.self)
        var fields = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if let q = fields.firstIndex(where: { $0.count == 3 && $0.hasPrefix("q") }) {
            fields = Array(fields[..<q])
        }
        fields.removeAll { $0 == "TCPIP*" || $0 == "TCPIP" }
        return Array(fields.joined(separator: ",").utf8) + line[colon...]
    }

    func testCorpusSurvivesFrameAndHDLC() throws {
        var converted = 0, skipped = 0
        var deframer = HDLCDeframer()
        for raw in try corpus() {
            let line = radioForm(raw)
            guard let frame = try? AX25Frame(tnc2: line) else { skipped += 1; continue }
            converted += 1
            XCTAssertEqual(frame.tnc2, line, String(decoding: line, as: UTF8.self))
            let bits = HDLC.bits(frame: frame.bytes, leadingFlags: 2, trailingFlags: 1)
            let frames = deframer.append(bits)
            XCTAssertEqual(frames.count, 1, String(decoding: line, as: UTF8.self))
            if let back = frames.first {
                XCTAssertEqual(try AX25Frame(bytes: back).tnc2, line)
            }
        }
        print("AX.25-Korpus: \(converted) umgesetzt, \(skipped) nicht als AX.25 darstellbar")
        // Nicht darstellbar sind z. B. Absender mit mehr als sechs Zeichen oder
        // Kleinbuchstaben — die gibt es nur im Internet, nicht auf Funk.
        XCTAssertGreaterThan(converted, 300)
        XCTAssertEqual(deframer.rejectedFrames, 0)
    }
}
