import Foundation

/// APRS-Frequenz einer Region für den Sendeschutz über Funk. Nur Werte mit
/// belegter Quelle (Recherche 21.11.2026, Plan APRS über Funk, F7); Regionen mit
/// widersprüchlichen Angaben fehlen bewusst — dort muss die Frequenz von Hand
/// bestätigt werden.
public enum APRSRadioRegion: String, CaseIterable, Codable, Sendable {
    /// IARU Region 1: Europa, Afrika, Naher Osten, Russland. IARU-R1-Bandplan.
    case iaruRegion1
    /// USA und Kanada. ARRL-Bandplan.
    case northAmerica
    case australia
    case newZealand

    public var frequencyHz: Int {
        switch self {
        case .iaruRegion1: return 144_800_000
        case .northAmerica: return 144_390_000
        case .australia: return 145_175_000
        case .newZealand: return 144_575_000
        }
    }

    /// Vorschlag aus dem Standort. Grobe Rechtecke, nur wo die Zuordnung
    /// eindeutig ist; an Grenzen und überall sonst nil — dann wählt der Nutzer.
    public static func suggested(latitude: Double, longitude: Double) -> APRSRadioRegion? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        switch (latitude, longitude) {
        case (24...72, -170 ... -52): return .northAmerica
        case (-45 ... -10, 112...155): return .australia
        case (-48 ... -34, 165...179): return .newZealand
        // Europa und Afrika bis zum Ural; östlich davon nur das nördliche Russland.
        case (-36...72, -26...45), (50...78, 45...180): return .iaruRegion1
        default: return nil
        }
    }
}

/// Entscheidet vor jeder Aussendung über Funk, ob die Frequenz passt
/// (Wunsch Chris 21.11.2026: nur auf der APRS-Frequenz senden, abschaltbar nur
/// mit Warnung).
public struct APRSTransmitGuard: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed
        /// Schutz ausgeschaltet: gesendet wird, die Oberfläche muss warnen.
        case allowedUnprotected
        /// Die Frequenz des Funkgeräts ist nicht bekannt (CAT getrennt).
        case blockedFrequencyUnknown
        /// Keine Region gewählt und keine Frequenz von Hand bestätigt.
        case blockedNoTargetFrequency
        case blockedOffFrequency(rigHz: Int, expectedHz: Int)
    }

    public var isEnabled = true
    /// Zielfrequenz; nil = weder Region noch eigene Frequenz gesetzt.
    public var expectedHz: Int?
    public var toleranceHz = 1_000

    public init(isEnabled: Bool = true, expectedHz: Int?, toleranceHz: Int = 1_000) {
        self.isEnabled = isEnabled
        self.expectedHz = expectedHz
        self.toleranceHz = max(0, toleranceHz)
    }

    public func check(rigFrequencyHz: Int?) -> Decision {
        guard isEnabled else { return .allowedUnprotected }
        guard let expectedHz else { return .blockedNoTargetFrequency }
        guard let rig = rigFrequencyHz, rig > 0 else { return .blockedFrequencyUnknown }
        return abs(rig - expectedHz) <= toleranceHz
            ? .allowed : .blockedOffFrequency(rigHz: rig, expectedHz: expectedHz)
    }
}
