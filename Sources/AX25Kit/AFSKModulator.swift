import Foundation

/// AFSK nach Bell 202 für 1200 Baud: Mark 1200 Hz, Space 2200 Hz,
/// phasenkontinuierlich. Die Bits werden NRZI-kodiert: eine Null wechselt den
/// Ton, eine Eins hält ihn.
public struct AFSKModulator: Sendable {
    public static let baud = 1200.0
    public static let markHz = 1200.0
    public static let spaceHz = 2200.0

    public let sampleRate: Double
    /// Spitzenwert der Sinusschwingung, 0…1.
    public var amplitude: Float = 0.5
    /// Ein- und Ausblenden gegen Knackser, in Sekunden.
    public var rampTime = 0.002

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    /// Audio für einen Rahmen (ohne Flags und FCS). `txDelay`: Dauer der
    /// Flags vor dem Rahmen, damit Sender und Gegenstation bereit sind.
    public func modulate(frame: [UInt8], txDelay: TimeInterval = 0.3, tail: TimeInterval = 0.03) -> [Float] {
        modulate(bits: HDLC.bits(frame: frame, leadingFlags: Self.flagCount(for: txDelay),
                                 trailingFlags: Self.flagCount(for: tail)))
    }

    /// Anzahl Flags, die mindestens `duration` füllen (ein Flag = 8 Bit).
    public static func flagCount(for duration: TimeInterval) -> Int {
        max(1, Int((duration * baud / 8).rounded(.up)))
    }

    /// Dauer der Aussendung in Sekunden für eine Bitfolge.
    public static func duration(bitCount: Int) -> TimeInterval {
        Double(bitCount) / baud
    }

    public func modulate(bits: [Bool]) -> [Float] {
        guard sampleRate > 0, !bits.isEmpty else { return [] }
        let samplesPerBit = sampleRate / Self.baud
        let total = Int((Double(bits.count) * samplesPerBit).rounded())
        var samples = [Float](repeating: 0, count: total)
        var phase = 0.0
        var isMark = true
        var position = 0
        for (index, bit) in bits.enumerated() {
            if !bit { isMark.toggle() }
            let step = 2 * Double.pi * (isMark ? Self.markHz : Self.spaceHz) / sampleRate
            // Bitgrenzen aus der Gesamtlänge gerechnet: kein Drift bei krummen Abtastraten.
            let end = min(total, Int((Double(index + 1) * samplesPerBit).rounded()))
            while position < end {
                samples[position] = amplitude * Float(sin(phase))
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                position += 1
            }
        }
        let ramp = min(total / 2, Int(rampTime * sampleRate))
        if ramp > 0 {
            for index in 0..<ramp {
                let gain = Float(index) / Float(ramp)
                samples[index] *= gain
                samples[total - 1 - index] *= gain
            }
        }
        return samples
    }
}
