import XCTest
@testable import AX25Kit

/// Empfangs-Decoder gegen den eigenen Modulator, mit Störungen wie auf dem Band:
/// Rauschen, Pegel, Taktabweichung, De-Emphase. Die Störungen sind simuliert —
/// das ersetzt keine Messung mit Signalen vom Band.
final class AFSKDemodulatorTests: XCTestCase {

    private let lines = [
        "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:=4733.09N/00917.34ElHAM-Tools",
        "N0CALL-7>APZHMT::N0OTHER-9:73 de Test{1",
        "N0CALL>APZHMT:;HB9XYZ-FD*211345z4730.00N/00915.00E;Fieldday 145.500"
    ]

    /// Deterministisches Rauschen (Box-Muller über einen festen Zufallsgenerator).
    private struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Float {
            let u = max(uniform(), 1e-12), v = uniform()
            return Float(sqrt(-2 * log(u)) * cos(2 * .pi * v))
        }
    }

    private func audio(_ line: String, sampleRate: Double = 48_000, amplitude: Float = 0.5,
                       silence: Double = 0.2) throws -> (frame: [UInt8], samples: [Float]) {
        let frame = try AX25Frame(tnc2: line).bytes
        var modulator = AFSKModulator(sampleRate: sampleRate)
        modulator.amplitude = amplitude
        let pad = [Float](repeating: 0, count: Int(silence * sampleRate))
        return (frame, pad + modulator.modulate(frame: frame, txDelay: 0.2) + pad)
    }

    private func decode(_ samples: [Float], sampleRate: Double = 48_000, chunk: Int = 4_096) -> [[UInt8]] {
        var demodulator = AFSKDemodulator(sampleRate: sampleRate)
        var frames: [[UInt8]] = []
        var index = 0
        while index < samples.count {
            frames += demodulator.process(Array(samples[index..<min(samples.count, index + chunk)]))
            index += chunk
        }
        return frames
    }

    // MARK: - Sauberes Signal

    func testCleanSignalAtCommonSampleRates() throws {
        for rate in [48_000.0, 44_100.0, 22_050.0] {
            for line in lines {
                let (frame, samples) = try audio(line, sampleRate: rate)
                XCTAssertEqual(decode(samples, sampleRate: rate), [frame], "\(line) bei \(rate) Hz")
            }
        }
    }

    func testChunkSizeDoesNotMatter() throws {
        let (frame, samples) = try audio(lines[0])
        for chunk in [1, 7, 480, 100_000] {
            XCTAssertEqual(decode(samples, chunk: chunk), [frame], "Blockgrösse \(chunk)")
        }
    }

    func testSeveralFramesInOneStreamCountOnce() throws {
        var samples: [Float] = []
        var expected: [[UInt8]] = []
        for line in lines {
            let (frame, part) = try audio(line, silence: 0.1)
            samples += part
            expected.append(frame)
        }
        var demodulator = AFSKDemodulator()
        XCTAssertEqual(demodulator.process(samples), expected)
        XCTAssertEqual(demodulator.framesDecoded, 3)
    }

    func testSilenceAndNoiseGiveNoFrames() {
        var noise = Noise(state: 99)
        let samples = (0..<(48_000 * 5)).map { _ in 0.3 * noise.gaussian() }
        XCTAssertEqual(decode(samples), [])
        XCTAssertEqual(decode([Float](repeating: 0, count: 48_000)), [])
    }

    // MARK: - Störungen

    func testLevelsFromQuietToLoud() throws {
        for amplitude: Float in [0.005, 0.05, 0.9] {
            let (frame, samples) = try audio(lines[0], amplitude: amplitude)
            XCTAssertEqual(decode(samples), [frame], "Pegel \(amplitude)")
        }
    }

    /// Takt des Senders bis ±1 % neben 1200 Baud (Soundkarten, Fremdgeräte).
    func testClockOffset() throws {
        for offset in [-0.01, -0.003, 0.003, 0.01] {
            let frame = try AX25Frame(tnc2: lines[0]).bytes
            // Mit falscher Rate erzeugt, mit 48 kHz gelesen = Takt- und Tonabweichung.
            let samples = AFSKModulator(sampleRate: 48_000 * (1 + offset)).modulate(frame: frame, txDelay: 0.2)
            XCTAssertEqual(decode(samples), [frame], "Abweichung \(offset * 100) %")
        }
    }

    /// De-Emphase (FM-Empfänger ohne flachen Datenausgang): 2200 Hz rund 6 dB leiser als 1200 Hz,
    /// und umgekehrt (Pre-Emphase ohne Ausgleich).
    func testToneTilt() throws {
        let frame = try AX25Frame(tnc2: lines[0]).bytes
        let clean = AFSKModulator().modulate(frame: frame, txDelay: 0.2)
        // Einpoliger Tiefpass bei rund 1,4 kHz dämpft 2200 Hz deutlich stärker als 1200 Hz.
        var lowpassed = [Float](repeating: 0, count: clean.count)
        let a: Float = 0.17
        var y: Float = 0
        for (index, x) in clean.enumerated() { y += a * (x - y); lowpassed[index] = y }
        XCTAssertEqual(decode(lowpassed), [frame], "Tiefpass (De-Emphase)")
        // Einfacher Hochpass (Differenz) hebt 2200 Hz an.
        var highpassed = [Float](repeating: 0, count: clean.count)
        for index in 1..<clean.count { highpassed[index] = clean[index] - 0.9 * clean[index - 1] }
        XCTAssertEqual(decode(highpassed), [frame], "Hochpass (Pre-Emphase)")
    }

    /// Weisses Rauschen über das ganze Audioband: Anteil dekodierter Rahmen je Störabstand.
    /// Die Schwellen sind bewusst vorsichtig; die gemessene Quote steht in der Ausgabe.
    func testDecodeRateUnderNoise() throws {
        let frame = try AX25Frame(tnc2: lines[0]).bytes
        let clean = AFSKModulator().modulate(frame: frame, txDelay: 0.2)
        let signalPower = clean.reduce(0) { $0 + $1 * $1 } / Float(clean.count)
        var noise = Noise(state: 7)
        var report: [String] = []
        for snr in [20.0, 10.0, 6.0, 3.0, 0.0, -3.0] {
            let sigma = sqrt(signalPower / Float(pow(10, snr / 10)))
            var decoded = 0
            let trials = 20
            for _ in 0..<trials {
                let noisy = clean.map { $0 + sigma * noise.gaussian() }
                if decode(noisy) == [frame] { decoded += 1 }
            }
            report.append("\(Int(snr)) dB: \(decoded)/\(trials)")
            switch snr {
            case 20: XCTAssertEqual(decoded, trials, "20 dB")
            case 10: XCTAssertGreaterThanOrEqual(decoded, trials * 9 / 10, "10 dB")
            default: break
            }
        }
        print("AFSK-Decoder unter weissem Rauschen (Störabstand über 0–24 kHz): " + report.joined(separator: ", "))
    }

    /// Rechenzeit: zehn Sekunden Audio bei 48 kHz. Die Grenze ist grosszügig
    /// (Debug-Build, langsamer Rechner); der gemessene Wert steht in der Ausgabe.
    func testProcessingSpeed() throws {
        let (_, part) = try audio(lines[0], silence: 0.5)
        var samples: [Float] = []
        while samples.count < 480_000 { samples += part }
        var demodulator = AFSKDemodulator()
        let started = Date()
        _ = demodulator.process(samples)
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "AFSK-Decoder: 10 s Audio in %.3f s (%.1f %% Echtzeit)", elapsed, elapsed * 10))
        XCTAssertLessThan(elapsed, 5)
    }
}
