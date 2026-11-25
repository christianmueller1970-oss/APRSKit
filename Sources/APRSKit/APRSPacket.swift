import Foundation

/// Ein APRS-Paket im TNC2-Textformat `QUELLE>ZIEL,PFAD:Nutzdaten`, wie es
/// APRS-IS liefert. Die Oberfläche kennt nur diesen Typ, nie den Transport.
///
/// Nutzdaten bleiben als Bytes erhalten: APRS-Pakete sind nicht zwingend
/// gültiges UTF-8, und Unbekanntes wird nie verworfen (`content == .unparsed`).
public struct APRSPacket: Equatable, Sendable {
    /// Absender, so wie empfangen (z. B. `HB9XYZ-9`).
    public let source: String
    /// Zieladresse (Tocall bzw. bei Mic-E der kodierte Breitengrad).
    public let destination: String
    /// Digipeater-Pfad samt q-Konstrukt von APRS-IS.
    public let path: [APRSPathElement]
    /// Alles nach dem ersten Doppelpunkt, unverändert.
    public let payload: [UInt8]
    /// Geparster Inhalt; `.unparsed`, wenn der Typ (noch) nicht erkannt wird
    /// oder die Nutzdaten nicht zum Typ passen.
    public let content: APRSContent

    public init(source: String, destination: String, path: [APRSPathElement],
                payload: [UInt8], content: APRSContent) {
        self.source = source
        self.destination = destination
        self.path = path
        self.payload = payload
        self.content = content
    }

    /// Schlüssel für Stationsspeicher und Vergleiche — immer normalisiert.
    public var sourceKey: String { source.uppercased() }

    /// Nutzdaten als Text: UTF-8, sonst Latin-1 (verliert kein Byte).
    public var payloadText: String { APRSText.decode(payload[...]) }

    /// Erstes Byte der Nutzdaten (APRS Data Type Identifier), falls vorhanden.
    public var dataTypeIdentifier: UInt8? { payload.first }
}

/// Ein Element des Pfads. `isUsed` entspricht dem `*` hinter dem Namen
/// («dieser Digipeater hat das Paket weitergereicht»).
public struct APRSPathElement: Equatable, Sendable {
    public let name: String
    public let isUsed: Bool

    public init(name: String, isUsed: Bool = false) {
        self.name = name
        self.isUsed = isUsed
    }
}

public indirect enum APRSContent: Equatable, Sendable {
    case position(APRSPositionReport)
    case object(APRSObjectReport)
    case item(APRSObjectReport)
    case status(APRSStatusReport)
    case message(APRSMessage)
    /// Wetterbericht ohne Position (`_`).
    case weather(APRSWeatherReport)
    case telemetry(APRSTelemetry)
    /// Von einem Gateway weitergereichtes Paket (`}`); enthält das innere Paket.
    case thirdParty(APRSPacket)
    /// Rohpaket: Kopf gültig, Inhalt nicht interpretiert.
    case unparsed
}

/// Positionsmeldung (Data Type `!`, `=`, `/`, `@`).
public struct APRSPositionReport: Equatable, Sendable {
    /// Grad, Nord positiv. Bei Unschärfe die Mitte des gemeldeten Felds.
    public let latitude: Double
    /// Grad, Ost positiv. Bei Unschärfe die Mitte des gemeldeten Felds.
    public let longitude: Double
    /// Positions-Unschärfe 0…4 = Anzahl weggelassener Stellen der Minuten.
    public let ambiguity: Int
    /// Symboltabelle (`/` primär, `\` alternativ) oder Overlay-Zeichen.
    public let symbolTable: Character
    public let symbolCode: Character
    /// Zeitstempel aus dem Paket; nil bei `!`/`=` oder ungültigen Ziffern.
    public let timestamp: APRSTimestamp?
    /// Station kann APRS-Messages empfangen (`=` und `@`).
    public let supportsMessaging: Bool
    /// Kurs in Grad 1…360 (360 = Nord); nil = nicht gemeldet.
    public let course: Int?
    /// Geschwindigkeit in Knoten.
    public let speedKnots: Double?
    /// Höhe in Fuss über Meer.
    public let altitudeFeet: Double?
    /// Vom Absender angegebene Funkreichweite in Meilen.
    public let radioRangeMiles: Double?
    /// Leistung, Antennenhöhe und Gewinn, falls gemeldet.
    public let phg: APRSPHG?
    /// Statusmeldung aus einem Mic-E-Paket; nil bei allen anderen Formaten.
    public let micEStatus: APRSMicEStatus?
    /// Wetterdaten einer Wetterstation (Symbolcode `_`).
    public let weather: APRSWeather?
    /// Freitext nach Position und Datenerweiterungen.
    public let comment: String

    public init(latitude: Double, longitude: Double, ambiguity: Int,
                symbolTable: Character, symbolCode: Character,
                timestamp: APRSTimestamp?, supportsMessaging: Bool,
                course: Int? = nil, speedKnots: Double? = nil,
                altitudeFeet: Double? = nil, radioRangeMiles: Double? = nil,
                phg: APRSPHG? = nil, micEStatus: APRSMicEStatus? = nil, weather: APRSWeather? = nil,
                comment: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.ambiguity = ambiguity
        self.symbolTable = symbolTable
        self.symbolCode = symbolCode
        self.timestamp = timestamp
        self.supportsMessaging = supportsMessaging
        self.course = course
        self.speedKnots = speedKnots
        self.altitudeFeet = altitudeFeet
        self.radioRangeMiles = radioRangeMiles
        self.phg = phg
        self.micEStatus = micEStatus
        self.weather = weather
        self.comment = comment
    }
}

/// Wetterdaten in den Einheiten des Protokolls; umgerechnet wird in der Anzeige.
/// nil = von der Station nicht gemeldet.
public struct APRSWeather: Equatable, Sendable {
    public var windDirectionDegrees: Int?
    public var windSpeedMph: Int?
    public var gustMph: Int?
    public var temperatureFahrenheit: Int?
    /// Regen in Hundertstel Zoll: letzte Stunde, letzte 24 h, seit Mitternacht.
    public var rainLastHour: Int?
    public var rainLast24Hours: Int?
    public var rainSinceMidnight: Int?
    public var humidityPercent: Int?
    /// Luftdruck in Zehntel Millibar (Hektopascal).
    public var pressureTenthsMillibar: Int?
    /// Helligkeit in Watt pro Quadratmeter.
    public var luminosity: Int?
    /// Schneefall der letzten 24 h in Zoll.
    public var snowLast24Hours: Double?

    public init() {}
}

public struct APRSWeatherReport: Equatable, Sendable {
    public let timestamp: APRSTimestamp?
    public let weather: APRSWeather
    /// Rest nach den Wetterfeldern (meist Software- und Gerätekennung).
    public let comment: String

    public init(timestamp: APRSTimestamp?, weather: APRSWeather, comment: String) {
        self.timestamp = timestamp
        self.weather = weather
        self.comment = comment
    }
}

/// Telemetrie (`T#Nr,a1,…,a5,bbbbbbbb`), roh: ohne Skalierung und Einheiten.
public struct APRSTelemetry: Equatable, Sendable {
    public let sequence: String
    /// Bis zu fünf Analogwerte; nil = Feld leer oder nicht lesbar.
    public let analog: [Double?]
    /// Bis zu acht Digitalwerte.
    public let digital: [Bool]
    public let comment: String

    public init(sequence: String, analog: [Double?], digital: [Bool], comment: String) {
        self.sequence = sequence
        self.analog = analog
        self.digital = digital
        self.comment = comment
    }
}

/// Die drei Message-Bits eines Mic-E-Pakets.
public enum APRSMicEStatus: Equatable, Sendable {
    /// Standardmeldung M0…M6: 0 Off Duty, 1 En Route, 2 In Service,
    /// 3 Returning, 4 Committed, 5 Special, 6 Priority.
    case standard(Int)
    /// Frei belegte Meldung C0…C6.
    case custom(Int)
    case emergency
}

/// Objekt (`;`) oder Item (`)`): eine Position mit eigenem Namen, gesetzt von
/// der Absenderstation.
public struct APRSObjectReport: Equatable, Sendable {
    /// Name ohne Füll-Leerzeichen.
    public let name: String
    /// false = «killed», das Objekt soll von der Karte verschwinden.
    public let isLive: Bool
    public let position: APRSPositionReport

    public init(name: String, isLive: Bool, position: APRSPositionReport) {
        self.name = name
        self.isLive = isLive
        self.position = position
    }
}

/// Statustext (`>`), optional mit Zeitstempel `DDHHMMz`.
public struct APRSStatusReport: Equatable, Sendable {
    public let timestamp: APRSTimestamp?
    public let text: String

    public init(timestamp: APRSTimestamp?, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

/// Message (`:ADRESSAT :Text{Nr`), Bestätigung oder Ablehnung.
public struct APRSMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text
        /// `ackNr`: die Gegenstation hat Nachricht `messageID` erhalten.
        case ack
        /// `rejNr`: die Gegenstation lehnt Nachricht `messageID` ab.
        case reject
    }

    /// Adressat ohne Füll-Leerzeichen, so wie gesendet.
    public let addressee: String
    public let kind: Kind
    /// Nachrichtentext; bei `ack`/`reject` leer.
    public let text: String
    /// Laufnummer der Nachricht bzw. die bestätigte/abgelehnte Nummer.
    public let messageID: String?
    /// Reply-Ack (`{MM}AA`): mit dieser Nachricht bestätigt der Absender
    /// zugleich unsere Nachricht `AA`.
    public let replyAckID: String?

    public init(addressee: String, kind: Kind, text: String,
                messageID: String?, replyAckID: String? = nil) {
        self.addressee = addressee
        self.kind = kind
        self.text = text
        self.messageID = messageID
        self.replyAckID = replyAckID
    }

    /// Schlüssel für Vergleiche mit dem eigenen Rufzeichen.
    public var addresseeKey: String { addressee.uppercased() }

    /// Bulletins und Announcements gehen an `BLN…` statt an eine Station.
    public var isBulletin: Bool { addresseeKey.hasPrefix("BLN") }
}

/// Zeitstempel, wie er im Paket steht. Er enthält weder Monat noch Jahr; das
/// Auflösen zu einem Datum braucht eine Bezugszeit und geschieht ausserhalb.
public enum APRSTimestamp: Equatable, Sendable {
    /// `DDHHMMz` (UTC) oder `DDHHMM/` (Ortszeit des Absenders).
    case dayHourMinute(day: Int, hour: Int, minute: Int, isUTC: Bool)
    /// `HHMMSSh`, immer UTC.
    case hourMinuteSecond(hour: Int, minute: Int, second: Int)
    /// `MMDDHHMM` in positionslosen Wetterberichten, UTC.
    case monthDayHourMinute(month: Int, day: Int, hour: Int, minute: Int)
}

enum APRSText {
    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? ""
    }
}
