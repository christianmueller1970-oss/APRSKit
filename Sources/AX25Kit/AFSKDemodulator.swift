import Foundation
import Accelerate

/// Empfangs-Decoder für AFSK 1200 Baud (Bell 202): Audio rein, AX.25-Rahmen
/// (ohne Flags und FCS, mit geprüfter FCS) raus. Zustand bleibt zwischen
/// Aufrufen erhalten, die Audio-Blöcke dürfen beliebig gross sein.
///
/// Aufbau je Entscheider: Mark- und Space-Ton werden mit Quadratur-Korrelatoren
/// über eine Bitlänge gemessen; die Differenz der Energien ist das weiche
/// Bit. Eine digitale PLL tastet in der Bitmitte ab und zieht ihre Phase an den
/// Tonwechseln nach. Danach NRZI und HDLC.
///
/// Vorher wird auf rund 12 kHz heruntergesetzt (Tiefpass, jeder n-te Wert): für
/// Töne bis 2200 Hz genügt das und spart drei Viertel der Rechenarbeit
/// (Mitschnitt 21.11.2026: Rechenzeit −72 %, 56 statt 57 Pakete).
///
/// Mehrere Entscheider mit verschieden gewichtetem Space-Ton laufen parallel:
/// FM-Geräte senden 1200 und 2200 Hz je nach Pre- und De-Emphase verschieden
/// laut. Ein Rahmen zählt einmal, egal wie viele Entscheider ihn finden.
public struct AFSKDemodulator: Sendable {
    public let sampleRate: Double
    public private(set) var framesDecoded = 0

    private var correlator: Correlator
    private var slicers: [Slicer]
    private var decimator: Decimator
    /// Abtastrate, mit der Korrelatoren und Entscheider tatsächlich rechnen.
    public let workingRate: Double
    /// Zuletzt gemeldete Rahmen mit ihrer Position, gegen Doppelmeldungen.
    private var recent: [(frame: [UInt8], sample: Int)] = []
    private var sampleCount = 0

    /// Gewichte des Space-Tons der einzelnen Entscheider, ±12 dB in 3-dB-Schritten.
    /// Gemessen am Mitschnitt vom IC-9700 (21.11.2026, 6 min, 144.800): mit drei
    /// Entscheidern (0, ±6 dB) 52 Pakete, mit diesen neun 63, mit nur einem 9 —
    /// die Töne kommen vom Band je nach Sender sehr verschieden laut an.
    public static let defaultSpaceGains: [Float] = [0.25, 0.35, 0.5, 0.7, 1.0, 1.4, 2.0, 2.8, 4.0]

    public init(sampleRate: Double = 48_000, spaceGains: [Float] = AFSKDemodulator.defaultSpaceGains) {
        self.sampleRate = sampleRate
        let gains = spaceGains.isEmpty ? [1.0] : spaceGains
        // Für Töne bis 2200 Hz genügen rund 12 kHz: ganzzahlig heruntersetzen.
        let factor = max(1, Int(sampleRate / AFSKDemodulator.targetRate))
        decimator = Decimator(factor: factor, sampleRate: sampleRate)
        let rate = sampleRate / Double(factor)
        workingRate = rate
        correlator = Correlator(sampleRate: rate)
        slicers = gains.map { Slicer(sampleRate: rate, spaceGain: $0) }
    }

    public mutating func process(_ samples: [Float]) -> [[UInt8]] {
        guard sampleRate > 0 else { return [] }
        var found: [[UInt8]] = []
        let window = Int(workingRate)   // eine Sekunde
        for sample in decimator.process(samples) {
            sampleCount += 1
            // Die Tonmessung ist für alle Entscheider gleich und läuft nur einmal.
            guard let (mark, space) = correlator.push(sample) else { continue }
            for index in slicers.indices {
                if let frame = slicers[index].push(mark: mark, space: space) {
                    if !recent.contains(where: { $0.frame == frame && sampleCount - $0.sample < window }) {
                        found.append(frame)
                        framesDecoded += 1
                    }
                    recent.append((frame, sampleCount))
                }
            }
        }
        recent.removeAll { sampleCount - $0.sample >= window }
        return found
    }

    /// Ziel der Abtastraten-Reduktion.
    static let targetRate = 12_000.0

    /// Tiefpass (gefensterter Sinc, Grenze 4 kHz) und Weglassen von Abtastwerten
    /// blockweise mit `vDSP_desamp`; die letzten Werte eines Blocks bleiben als
    /// Vorgeschichte für den nächsten stehen, damit es an Blockgrenzen nicht springt.
    struct Decimator: Sendable {
        let factor: Int
        private let taps: [Float]
        /// Vorgeschichte plus noch nicht verbrauchte Werte.
        private var buffer: [Float] = []

        init(factor: Int, sampleRate: Double) {
            self.factor = factor
            // Länge und Grenze am Mitschnitt vom IC-9700 gewählt (21.11.2026): 8 Taps je
            // Faktor und 4 kHz; längere Filter oder andere Grenzen brachten nichts mehr.
            let count = factor == 1 ? 1 : 8 * factor + 1
            let cutoff = min(4_000, 0.45 * sampleRate / Double(factor)) / sampleRate
            var coefficients: [Float] = []
            let middle = Double(count - 1) / 2
            for n in 0..<count {
                let x = Double(n) - middle
                let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
                let window = count == 1 ? 1 : 0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(count - 1))
                coefficients.append(Float(sinc * window))
            }
            let sum = coefficients.reduce(0, +)
            taps = coefficients.map { $0 / sum }
            buffer = Array(repeating: 0, count: count - 1)
        }

        mutating func process(_ samples: [Float]) -> [Float] {
            guard factor > 1 else { return samples }
            buffer.append(contentsOf: samples)
            let available = buffer.count - (taps.count - 1)
            let outputs = available / factor
            guard outputs > 0 else { return [] }
            var result = [Float](repeating: 0, count: outputs)
            buffer.withUnsafeBufferPointer { input in
                taps.withUnsafeBufferPointer { filter in
                    vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), filter.baseAddress!,
                                &result, vDSP_Length(outputs), vDSP_Length(filter.count))
                }
            }
            buffer.removeFirst(outputs * factor)
            return result
        }
    }

    /// Quadratur-Korrelatoren für Mark und Space über eine Bitlänge. Die
    /// Mischfrequenzen kommen aus einer rekursiv gedrehten Zeigerdarstellung
    /// statt aus `sin`/`cos` je Abtastwert; alle 4096 Schritte wird sie neu
    /// normiert, damit sich keine Rundungsfehler ansammeln.
    struct Correlator: Sendable {
        private let window: Int
        private let markRotation: SIMD2<Double>
        private let spaceRotation: SIMD2<Double>
        private var markPhasor = SIMD2<Double>(1, 0)
        private var spacePhasor = SIMD2<Double>(1, 0)
        private var ring: [SIMD4<Float>]
        private var sum = SIMD4<Float>(repeating: 0)
        private var ringIndex = 0
        private var filled = 0
        private var steps = 0

        init(sampleRate: Double) {
            window = max(4, Int((sampleRate / AFSKModulator.baud).rounded()))
            let mark = 2 * Double.pi * AFSKModulator.markHz / sampleRate
            let space = 2 * Double.pi * AFSKModulator.spaceHz / sampleRate
            markRotation = SIMD2(cos(mark), sin(mark))
            spaceRotation = SIMD2(cos(space), sin(space))
            ring = Array(repeating: SIMD4<Float>(repeating: 0), count: window)
        }

        private static func rotate(_ p: SIMD2<Double>, _ r: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(p.x * r.x - p.y * r.y, p.x * r.y + p.y * r.x)
        }

        /// Liefert die Energien von Mark und Space, sobald ein Bit Audio vorliegt.
        mutating func push(_ sample: Float) -> (mark: Float, space: Float)? {
            let mixed = SIMD4<Float>(sample * Float(markPhasor.x), sample * Float(markPhasor.y),
                                     sample * Float(spacePhasor.x), sample * Float(spacePhasor.y))
            markPhasor = Self.rotate(markPhasor, markRotation)
            spacePhasor = Self.rotate(spacePhasor, spaceRotation)
            steps += 1
            if steps >= 4096 {
                steps = 0
                markPhasor /= (markPhasor.x * markPhasor.x + markPhasor.y * markPhasor.y).squareRoot()
                spacePhasor /= (spacePhasor.x * spacePhasor.x + spacePhasor.y * spacePhasor.y).squareRoot()
            }
            sum += mixed - ring[ringIndex]
            ring[ringIndex] = mixed
            ringIndex = (ringIndex + 1) % window
            // Gleitende Summe gelegentlich neu bilden, damit Float-Fehler nicht wandern.
            if ringIndex == 0 { sum = ring.reduce(SIMD4<Float>(repeating: 0), +) }
            if filled < window { filled += 1; return nil }
            return (sum.x * sum.x + sum.y * sum.y, sum.z * sum.z + sum.w * sum.w)
        }
    }

    /// Ein Entscheider: weiches Bit mit eigener Gewichtung, PLL, NRZI, HDLC.
    struct Slicer: Sendable {
        let spaceGain: Float
        private let bitStep: Double
        private var bitPhase = 0.0
        private var lastSoft: Float = 0
        private var lastTone = false
        private var deframer = HDLCDeframer()

        /// Wie stark die PLL an einem Tonwechsel nachzieht (0 = gar nicht, 1 = ganz).
        static let pllGain = 0.3
        /// Unter diesem Pegel (Summe beider Töne) wird nichts entschieden.
        static let squelch: Float = 1e-9

        init(sampleRate: Double, spaceGain: Float) {
            self.spaceGain = spaceGain
            bitStep = AFSKModulator.baud / sampleRate
        }

        mutating func push(mark: Float, space rawSpace: Float) -> [UInt8]? {
            let space = rawSpace * spaceGain * spaceGain
            let total = mark + space
            let soft: Float = total > Self.squelch ? (mark - space) / total : 0
            // PLL: an einem Vorzeichenwechsel liegt die Bitgrenze; dort soll die Phase 0,5 sein,
            // abgetastet wird beim Überlauf auf 1 — also in der Bitmitte.
            if (soft > 0) != (lastSoft > 0), soft != 0, lastSoft != 0 {
                bitPhase += (0.5 - bitPhase) * Self.pllGain
            }
            lastSoft = soft
            bitPhase += bitStep
            guard bitPhase >= 1 else { return nil }
            bitPhase -= 1
            let tone = soft > 0
            let bit = tone == lastTone   // NRZI: gleicher Ton = 1, Wechsel = 0
            lastTone = tone
            return deframer.append(CollectionOfOne(bit)).first
        }
    }
}
