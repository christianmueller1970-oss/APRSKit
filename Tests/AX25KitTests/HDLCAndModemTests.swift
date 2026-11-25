import XCTest
@testable import AX25Kit

final class HDLCAndModemTests: XCTestCase {

    // MARK: - FCS und Rahmung

    /// Bekannter Prüfwert der CRC-16/X.25.
    func testFCSCheckValue() {
        XCTAssertEqual(HDLC.fcs(Array("123456789".utf8)), 0x906E)
        XCTAssertEqual(HDLC.fcs([]), 0x0000)
    }

    func testFlagsAndStuffing() {
        // Acht Einsen im Rahmen: nach der fünften wird eine Null eingefügt.
        let bits = HDLC.bits(frame: [0xFF], leadingFlags: 1, trailingFlags: 1)
        let flag = [false, true, true, true, true, true, true, false]
        XCTAssertEqual(Array(bits.prefix(8)), flag)
        XCTAssertEqual(Array(bits.suffix(8)), flag)
        XCTAssertEqual(Array(bits[8..<14]), [true, true, true, true, true, false])
        // Im Rahmen selbst stehen nie sechs Einsen in Folge.
        var run = 0
        for bit in bits.dropFirst(8).dropLast(8) {
            run = bit ? run + 1 : 0
            XCTAssertLessThan(run, 6)
        }
    }

    func testDeframerRoundTrip() throws {
        let frames: [[UInt8]] = [
            try AX25Frame(tnc2: "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:=4733.09N/00917.34ElHAM-Tools").bytes,
            try AX25Frame(tnc2: Array("N0CALL>APZHMT:".utf8) + [0xFF, 0xFF, 0x7E, 0x7E, 0x00, 0xFF, 0x3F, 0xFC]).bytes,
            try AX25Frame(tnc2: "N0CALL>APZHMT:" + String(repeating: "~", count: 256)).bytes
        ]
        var deframer = HDLCDeframer()
        var bits: [Bool] = []
        for frame in frames {
            bits += HDLC.bits(frame: frame, leadingFlags: 4, trailingFlags: 1)
        }
        XCTAssertEqual(deframer.append(bits), frames)
        XCTAssertEqual(deframer.rejectedFrames, 0)
    }

    /// Grösster zulässiger Rahmen: acht Digipeater und 256 Byte Information
    /// (Codex-Review 21.11.2026: wurde vom Pufferlimit verworfen).
    func testDeframerAcceptsMaximumFrame() throws {
        let path = (1...8).map { "N0DIG\($0)" }.joined(separator: ",")
        let frame = try AX25Frame(tnc2: "N0CALL-15>APZHMT,\(path):" + String(repeating: "x", count: 256)).bytes
        XCTAssertEqual(frame.count + 2, HDLCDeframer.maxFrameBytes)
        var deframer = HDLCDeframer()
        XCTAssertEqual(deframer.append(HDLC.bits(frame: frame, leadingFlags: 2, trailingFlags: 1)), [frame])
        XCTAssertEqual(deframer.rejectedFrames, 0)
        // Auch mit 0xFF-Information (maximales Bit-Stuffing).
        let stuffed = try AX25Frame(tnc2: Array("N0CALL-15>APZHMT,\(path):".utf8) + Array(repeating: 0xFF, count: 256)).bytes
        XCTAssertEqual(deframer.append(HDLC.bits(frame: stuffed, leadingFlags: 2, trailingFlags: 1)), [stuffed])
    }

    /// Bitweise angeliefert und mit Rauschen davor: gleiche Rahmen.
    func testDeframerHandlesNoiseAndSingleBits() throws {
        let frame = try AX25Frame(tnc2: "N0CALL-7>APZHMT:>Test").bytes
        var deframer = HDLCDeframer()
        var state: UInt64 = 7
        var found: [[UInt8]] = []
        for _ in 0..<5_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            found += deframer.append([state >> 40 & 1 != 0])
        }
        XCTAssertEqual(found, [])        // Rauschen ergibt keinen Rahmen mit gültiger FCS
        for bit in HDLC.bits(frame: frame, leadingFlags: 8, trailingFlags: 2) {
            found += deframer.append([bit])
        }
        XCTAssertEqual(found, [frame])
    }

    func testDeframerRejectsDamagedFrame() throws {
        let frame = try AX25Frame(tnc2: "N0CALL-7>APZHMT:>Test").bytes
        var bits = HDLC.bits(frame: frame, leadingFlags: 2, trailingFlags: 2)
        bits[60].toggle()
        var deframer = HDLCDeframer()
        XCTAssertEqual(deframer.append(bits), [])
    }

    // MARK: - Modulator

    func testAudioLengthAndLevel() throws {
        let frame = try AX25Frame(tnc2: "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:=4733.09N/00917.34ElHAM-Tools").bytes
        let modulator = AFSKModulator(sampleRate: 48_000)
        let bits = HDLC.bits(frame: frame, leadingFlags: AFSKModulator.flagCount(for: 0.3),
                             trailingFlags: AFSKModulator.flagCount(for: 0.03))
        let samples = modulator.modulate(frame: frame)
        XCTAssertEqual(samples.count, bits.count * 40)
        XCTAssertEqual(Double(samples.count) / 48_000, AFSKModulator.duration(bitCount: bits.count), accuracy: 1e-9)
        // Vorlauf mindestens 300 ms, die ganze Aussendung unter einer Sekunde.
        XCTAssertGreaterThanOrEqual(Double(AFSKModulator.flagCount(for: 0.3) * 8) / 1200, 0.3)
        XCTAssertLessThan(Double(samples.count) / 48_000, 1.0)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 1, 0.5 + 1e-6)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.49)
        XCTAssertEqual(samples.first, 0)
    }

    /// Phasenkontinuität: kein Sprung zwischen zwei Abtastwerten, der grösser ist
    /// als der steilste Anstieg des höheren Tons.
    func testPhaseContinuity() throws {
        let frame = try AX25Frame(tnc2: "N0CALL>APZHMT:>Phasentest 0123456789").bytes
        for rate in [48_000.0, 44_100.0, 22_050.0] {
            var modulator = AFSKModulator(sampleRate: rate)
            modulator.rampTime = 0
            let samples = modulator.modulate(frame: frame, txDelay: 0.05)
            let limit = Float(0.5 * 2 * Double.pi * AFSKModulator.spaceHz / rate) * 1.01
            for index in 1..<samples.count {
                XCTAssertLessThanOrEqual(abs(samples[index] - samples[index - 1]), limit, "Rate \(rate), Index \(index)")
            }
        }
    }

    /// Rundlauf ohne Funk: Audio erzeugen, je Bit den stärkeren Ton bestimmen,
    /// NRZI auflösen, Rahmen zurückgewinnen. Der Ton-Vergleich hier ist nur ein
    /// Prüfmittel mit bekanntem Takt, kein Empfangs-Decoder.
    func testModulatedAudioDecodesBackToFrame() throws {
        let lines = [
            "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:=4733.09N/00917.34ElHAM-Tools",
            "N0CALL-7>APZHMT::N0OTHER-9:73 de Test{1",
            "N0CALL>APZHMT:;HB9XYZ-FD*211345z4730.00N/00915.00E;Fieldday 145.500"
        ]
        for rate in [48_000.0, 44_100.0] {
            for line in lines {
                let frame = try AX25Frame(tnc2: line).bytes
                let samples = AFSKModulator(sampleRate: rate).modulate(frame: frame, txDelay: 0.1)
                let decoded = Self.framesFromAudio(samples, sampleRate: rate)
                XCTAssertEqual(decoded, [frame], "\(line) bei \(rate) Hz")
                XCTAssertEqual(try decoded.first.map { String(decoding: try AX25Frame(bytes: $0).tnc2, as: UTF8.self) }, line)
            }
        }
    }

    private static func framesFromAudio(_ samples: [Float], sampleRate: Double) -> [[UInt8]] {
        let samplesPerBit = sampleRate / AFSKModulator.baud
        let bitCount = Int((Double(samples.count) / samplesPerBit).rounded())
        func energy(_ range: Range<Int>, _ frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for index in range {
                let angle = 2 * Double.pi * frequency * Double(index) / sampleRate
                real += Double(samples[index]) * cos(angle)
                imaginary += Double(samples[index]) * sin(angle)
            }
            return real * real + imaginary * imaginary
        }
        var bits: [Bool] = []
        var previousMark = true
        for bit in 0..<bitCount {
            let start = Int((Double(bit) * samplesPerBit).rounded())
            let end = min(samples.count, Int((Double(bit + 1) * samplesPerBit).rounded()))
            guard end > start else { continue }
            let isMark = energy(start..<end, AFSKModulator.markHz) > energy(start..<end, AFSKModulator.spaceHz)
            bits.append(isMark == previousMark)      // NRZI: gleicher Ton = 1, Wechsel = 0
            previousMark = isMark
        }
        var deframer = HDLCDeframer()
        return deframer.append(bits)
    }
}
