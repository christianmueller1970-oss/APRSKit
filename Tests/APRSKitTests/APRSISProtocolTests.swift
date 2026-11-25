import XCTest
@testable import APRSKit

final class APRSISProtocolTests: XCTestCase {

    // MARK: - Login

    func testLoginLine() {
        XCTAssertEqual(
            APRSIS.loginLine(callsign: " n0call-7 ", software: "HAM-Tools", version: "1.2.3",
                             filter: "r/47.40/8.50/150"),
            "user N0CALL-7 pass -1 vers HAM-Tools 1.2.3 filter r/47.40/8.50/150")
        XCTAssertEqual(
            APRSIS.loginLine(callsign: "N0CALL", software: "HAM-Tools", version: "1.0", filter: "  "),
            "user N0CALL pass -1 vers HAM-Tools 1.0")
    }

    func testLoginLineRejectsBadInput() {
        func line(_ call: String, software: String = "X", version: String = "1") -> String? {
            APRSIS.loginLine(callsign: call, software: software, version: version, filter: "")
        }
        for call in ["", "AB", "N0CALL\r\nuser X", "N0 CALL", "N0CALL--1", "-N0CALL", "N0CALL-", "TOOLONGCALL", "N0CÄLL"] {
            XCTAssertNil(line(call), call)
        }
        XCTAssertNil(line("N0CALL", software: "HAM Tools"))
        XCTAssertNil(line("N0CALL", version: ""))
    }

    func testFilterCannotInjectASecondLine() {
        let line = APRSIS.loginLine(callsign: "N0CALL", software: "X", version: "1",
                                    filter: "r/47/8/50\r\nN0CALL>APRS:>boese\t t/m ")
        XCTAssertEqual(line, "user N0CALL pass -1 vers X 1 filter r/47/8/50 N0CALL>APRS:>boese t/m")
        XCTAssertFalse(line?.contains("\n") ?? true)
    }

    func testRangeFilter() {
        XCTAssertEqual(APRSIS.rangeFilter(latitude: 47.4567, longitude: 8.5432, kilometres: 150),
                       "r/47.46/8.54/150")
        XCTAssertEqual(APRSIS.rangeFilter(latitude: -33.5, longitude: -70.25, kilometres: 20),
                       "r/-33.50/-70.25/20")
        XCTAssertNil(APRSIS.rangeFilter(latitude: 91, longitude: 0, kilometres: 10))
        XCTAssertNil(APRSIS.rangeFilter(latitude: 0, longitude: 0, kilometres: 0))
    }

    // MARK: - Serverzeilen

    func testServerLines() {
        func parse(_ text: String) -> APRSISServerLine? { APRSISServerLine(Array(text.utf8)) }
        XCTAssertEqual(parse("# logresp N0CALL unverified, server T2TEST"),
                       .loginResponse(callsign: "N0CALL", isVerified: false, server: "T2TEST"))
        XCTAssertEqual(parse("# logresp N0CALL verified, server T2TEST, adjunct \"filter r/1/2/3\""),
                       .loginResponse(callsign: "N0CALL", isVerified: true, server: "T2TEST"))
        XCTAssertEqual(parse("# logresp N0CALL verified"),
                       .loginResponse(callsign: "N0CALL", isVerified: true, server: nil))
        XCTAssertEqual(parse("# Login by user not allowed"), .loginRejected("Login by user not allowed"))
        XCTAssertEqual(parse("# aprsc 3.0.1-g79fe075"), .comment("aprsc 3.0.1-g79fe075"))
        XCTAssertEqual(parse("#"), .comment(""))
        XCTAssertNil(parse("N0CALL>APRS:>x"))
        XCTAssertNil(parse(""))
    }

    // MARK: - Zeilen

    func testSplitterHandlesChunksAndLineEndings() {
        var splitter = APRSISLineSplitter()
        XCTAssertEqual(splitter.append(Array("# banner\r\nN0CALL>AP".utf8)), [Array("# banner".utf8)])
        XCTAssertEqual(splitter.append(Array("RS:>x\r".utf8)), [])
        XCTAssertEqual(splitter.append(Array("\n\r\n\nA>B:>y\n".utf8)),
                       [Array("N0CALL>APRS:>x".utf8), Array("A>B:>y".utf8)])
        XCTAssertEqual(splitter.discardedLines, 0)
    }

    func testSplitterDropsOverlongLineAndRecovers() {
        var splitter = APRSISLineSplitter(maxLineBytes: 16)
        var lines = splitter.append(Array(repeating: UInt8(ascii: "x"), count: 5_000))
        XCTAssertEqual(lines, [])
        lines = splitter.append(Array("xxxx\nA>B:>ok\r\n".utf8))
        XCTAssertEqual(lines, [Array("A>B:>ok".utf8)])
        XCTAssertEqual(splitter.discardedLines, 1)
        // Genau an der Grenze: 16 Bytes plus `\r\n` sind zulässig.
        lines = splitter.append(Array("0123456789ABCDEF\r\n".utf8))
        XCTAssertEqual(lines, [Array("0123456789ABCDEF".utf8)])
    }

    func testSplitterResetForgetsPartialLine() {
        var splitter = APRSISLineSplitter()
        _ = splitter.append(Array("halbe Zei".utf8))
        splitter.reset()
        XCTAssertEqual(splitter.append(Array("A>B:>neu\n".utf8)), [Array("A>B:>neu".utf8)])
    }

    /// Der ganze Korpus, in zufällig grosse Stücke zerlegt, ergibt dieselben Zeilen.
    func testSplitterReassemblesCorpus() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/corpus.txt")
        let data = Array(try Data(contentsOf: url))
        let expected = data.split(separator: UInt8(ascii: "\n")).map(Array.init)
        var splitter = APRSISLineSplitter()
        var lines: [[UInt8]] = []
        var offset = 0
        var state: UInt64 = 42
        while offset < data.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let size = 1 + Int((state >> 33) % 700)
            lines += splitter.append(data[offset..<min(data.count, offset + size)])
            offset += size
        }
        XCTAssertEqual(lines, expected)
        XCTAssertEqual(splitter.discardedLines, 0)
    }

    // MARK: - Backoff

    func testBackoffDoublesUpToMaximumAndResets() {
        var backoff = APRSISBackoff(initial: 5, maximum: 300)
        XCTAssertEqual((0..<9).map { _ in backoff.nextDelay() }, [5, 10, 20, 40, 80, 160, 300, 300, 300])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 5)
    }
}
