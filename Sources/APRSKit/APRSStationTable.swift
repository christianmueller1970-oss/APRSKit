import Foundation

/// Art des Eintrags im Stationsspeicher.
public enum APRSStationKind: String, Equatable, Sendable {
    case station
    case object
    case item
}

/// Grobe Einteilung für die Filter der Oberfläche.
public enum APRSStationCategory: String, CaseIterable, Equatable, Sendable {
    case moving
    case fixed
    case digipeater
    case gateway
    case weather
    case object
}

public struct APRSTrackPoint: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let time: Date
}

/// Was der Speicher über eine Station, ein Objekt oder ein Item weiss.
public struct APRSStation: Equatable, Identifiable, Sendable {
    /// Schlüssel im Speicher: bei Stationen der normalisierte Name, bei Objekten
    /// und Items mit vorangestelltem `;` bzw. `)` — siehe `APRSStationTable.key`.
    public let id: String
    /// Normalisierter Name (Grossbuchstaben) für Suche und Sortierung.
    public let nameKey: String
    /// Name, wie zuletzt empfangen.
    public var name: String
    public let kind: APRSStationKind
    /// Bei Objekten und Items: die Station, die sie setzt.
    public var owner: String?

    public var latitude: Double?
    public var longitude: Double?
    public var ambiguity = 0
    public var symbolTable: Character?
    public var symbolCode: Character?
    public var course: Int?
    public var speedKnots: Double?
    public var altitudeFeet: Double?
    public var phg: APRSPHG?
    public var radioRangeMiles: Double?
    public var supportsMessaging = false
    public var comment = ""
    public var status = ""
    public var weather: APRSWeather?
    public var telemetry: APRSTelemetry?

    /// Empfangszeit des ersten und des letzten Pakets.
    public var firstHeard: Date
    public var lastHeard: Date
    /// Empfangszeit der letzten Position.
    public var lastPositionAt: Date?
    public var packetCount = 0
    /// Pfad des letzten Pakets (inkl. q-Konstrukt).
    public var lastPath: [APRSPathElement] = []
    /// Das letzte Paket ist eine eigene Aussendung, lokal eingetragen — sein Pfad
    /// beschreibt, wie es gesendet wurde, nicht wie es jemand empfangen hat.
    public var lastPacketIsOwn = false
    /// Zuletzt vom eigenen Empfänger über Funk gehört (nicht über APRS-IS). nil = nie.
    public var lastHeardOnRadio: Date?
    /// Vom eigenen Empfänger über Funk gehörte Pakete.
    public var radioPacketCount = 0
    /// Das letzte Paket kam über den eigenen Empfänger.
    public var lastPacketViaRadio = false
    /// Digipeater, über die das zuletzt selbst gehörte Paket lief (0 = direkt).
    public var lastRadioHops: Int?
    /// Zuletzt über das Internet gehört: `TCPIP`/`TCPXX` im Pfad eines Pakets
    /// von APRS-IS, oder die Station trat auf Funk selbst als iGate auf.
    public var lastHeardViaInternet: Date?
    /// Ältester Punkt zuerst; die aktuelle Position ist der letzte Punkt.
    public var track: [APRSTrackPoint] = []

    public var hasPosition: Bool { latitude != nil && longitude != nil }

    public var category: APRSStationCategory {
        if kind != .station { return .object }
        if weather != nil || symbolCode == "_" { return .weather }
        if symbolCode == "#" { return .digipeater }
        if symbolCode == "&" { return .gateway }
        if (speedKnots ?? 0) > 0 || track.count > 1 { return .moving }
        return .fixed
    }
}

/// Stationsspeicher im RAM: wertet Pakete aus und hält je Station den letzten
/// Stand samt Track. Reiner Werttyp ohne Uhr — die Empfangszeit kommt vom
/// Aufrufer, damit sich ein aufgezeichneter Datenstrom genauso verhält wie ein
/// laufender.
public struct APRSStationTable: Sendable {
    /// Obergrenze der Einträge; darüber fällt der am längsten nicht gehörte weg.
    public var maxStations: Int
    /// Obergrenze der Track-Punkte je Station.
    public var maxTrackPoints: Int
    /// Kleinere Bewegungen (in Grad) ergeben keinen neuen Track-Punkt.
    public var minTrackDelta = 0.0001

    public private(set) var stations: [String: APRSStation] = [:]
    /// Zählt Änderungen, damit die Oberfläche nur bei Bedarf neu rechnet.
    public private(set) var revision = 0

    public init(maxStations: Int = 5000, maxTrackPoints: Int = 100) {
        self.maxStations = max(1, maxStations)
        self.maxTrackPoints = max(1, maxTrackPoints)
    }

    public var count: Int { stations.count }

    /// Normalisierter Name: ohne Rand-Leerzeichen, in Grossbuchstaben.
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Schlüssel eines Eintrags. Objekte und Items haben einen eigenen
    /// Schlüsselraum: ein Objekt, das wie eine Station heisst, darf deren
    /// Eintrag weder überschreiben noch mit einer Kill-Meldung löschen
    /// (Codex-Review 21.11.2026). `;` und `)` können in einem Rufzeichen aus
    /// dem Paketkopf nicht am Anfang stehen, weil dort kein Objektname steht —
    /// und selbst wenn, bliebe der Eintrag nur unter sich.
    public static func key(_ name: String, kind: APRSStationKind) -> String {
        switch kind {
        case .station: return key(name)
        case .object: return ";" + key(name)
        case .item: return ")" + key(name)
        }
    }

    /// Verarbeitet ein Paket und liefert die Schlüssel der geänderten Einträge.
    /// `isOwn`: eine eigene Aussendung, die APRS-IS nicht zurückschickt und
    /// deshalb direkt eingetragen wird. `transport`: Weg, auf dem das Paket
    /// hier ankam — `.radio` heisst: vom eigenen Empfänger gehört.
    @discardableResult
    public mutating func ingest(_ packet: APRSPacket, receivedAt: Date, isOwn: Bool = false,
                                transport: APRSTransport = .internet) -> [String] {
        // Third-Party: es zählt die Station im inneren Paket, nicht das Gateway.
        // Ein über Funk gehörtes Third-Party-Paket hat ein iGate ausgesendet,
        // nicht die Station selbst: sie gilt nicht als «über Funk gehört».
        if case .thirdParty(let inner) = packet.content {
            // Wer auf Funk Pakete aus dem Internet aussendet, ist selbst ein iGate
            // und damit über das Internet erreichbar (Regel für Internet → Funk).
            // Der Eintrag wird bei Bedarf angelegt: sonst ginge die Erkennung
            // verloren, wenn das iGate hier zum ersten Mal gehört wird
            // (Codex-Review 21.11.2026). Gehört wurde es dabei über Funk.
            if transport == .radio, !isOwn, Self.hasInternetMarker(inner.path) {
                _ = touch(name: packet.source, kind: .station, at: receivedAt) { station in
                    station.packetCount += 1
                    station.radioPacketCount += 1
                    station.lastHeardOnRadio = max(station.lastHeardOnRadio ?? receivedAt, receivedAt)
                    station.lastHeardViaInternet = max(station.lastHeardViaInternet ?? receivedAt, receivedAt)
                }
            }
            return ingest(inner, receivedAt: receivedAt, isOwn: isOwn, transport: .internet)
        }
        let heardOnRadio = transport == .radio && !isOwn
        var changed: [String] = []
        let sourceKey = touch(name: packet.source, kind: .station, at: receivedAt) { station in
            station.packetCount += 1
            station.lastPath = packet.path
            station.lastPacketIsOwn = isOwn
            station.lastPacketViaRadio = heardOnRadio
            if heardOnRadio {
                station.radioPacketCount += 1
                station.lastHeardOnRadio = max(station.lastHeardOnRadio ?? receivedAt, receivedAt)
                station.lastRadioHops = station.usedDigipeaters.count
            } else if transport == .internet, !isOwn, Self.hasInternetMarker(packet.path) {
                station.lastHeardViaInternet = max(station.lastHeardViaInternet ?? receivedAt, receivedAt)
            }
        }
        changed.append(sourceKey)

        switch packet.content {
        case .position(let report):
            let limits = trackLimits
            update(sourceKey) { $0.apply(report, at: receivedAt, limits: limits) }
        case .object(let object):
            changed.append(contentsOf: ingest(object, kind: .object, owner: packet.source,
                                              path: packet.path, at: receivedAt))
        case .item(let item):
            changed.append(contentsOf: ingest(item, kind: .item, owner: packet.source,
                                              path: packet.path, at: receivedAt))
        case .status(let status):
            update(sourceKey) { $0.status = status.text }
        case .weather(let report):
            update(sourceKey) { $0.weather = report.weather }
        case .telemetry(let telemetry):
            update(sourceKey) { $0.telemetry = telemetry }
        case .message, .unparsed, .thirdParty:
            break
        }
        // Auch Objekte und Items aus einem über Funk gehörten Paket sind «über Funk gehört».
        for key in changed where key != sourceKey {
            update(key) { entry in
                entry.lastPacketViaRadio = heardOnRadio
                if heardOnRadio {
                    entry.radioPacketCount += 1
                    entry.lastHeardOnRadio = max(entry.lastHeardOnRadio ?? receivedAt, receivedAt)
                }
            }
        }
        revision += 1
        evictIfNeeded(keeping: Set(changed))
        return changed
    }

    /// Entfernt alles, was länger als `maxAge` nicht gehört wurde. Gerechnet
    /// wird gegen das übergebene `now`, nie gegen die Systemuhr.
    @discardableResult
    public mutating func expire(maxAge: TimeInterval, now: Date) -> Int {
        let before = stations.count
        stations = stations.filter { now.timeIntervalSince($0.value.lastHeard) <= maxAge }
        let removed = before - stations.count
        if removed > 0 { revision += 1 }
        return removed
    }

    public mutating func removeAll() {
        guard !stations.isEmpty else { return }
        stations.removeAll()
        revision += 1
    }

    // MARK: - Intern

    private static func hasInternetMarker(_ path: [APRSPathElement]) -> Bool {
        path.contains { ["TCPIP", "TCPXX"].contains($0.name.uppercased()) }
    }

    fileprivate struct TrackLimits {
        let maxPoints: Int
        let minDelta: Double
    }

    private var trackLimits: TrackLimits {
        TrackLimits(maxPoints: maxTrackPoints, minDelta: minTrackDelta)
    }

    private mutating func ingest(_ object: APRSObjectReport, kind: APRSStationKind, owner: String,
                                 path: [APRSPathElement], at time: Date) -> [String] {
        guard !Self.key(object.name).isEmpty else { return [] }
        let key = Self.key(object.name, kind: kind)
        guard object.isLive else {
            // «Killed»: verschwindet von Karte und Liste.
            stations[key] = nil
            return [key]
        }
        _ = touch(name: object.name, kind: kind, at: time) { station in
            station.owner = owner
            station.packetCount += 1
            station.lastPath = path
        }
        let limits = trackLimits
        update(key) { $0.apply(object.position, at: time, limits: limits) }
        return [key]
    }

    private mutating func touch(name: String, kind: APRSStationKind, at time: Date,
                                _ change: (inout APRSStation) -> Void) -> String {
        let key = Self.key(name, kind: kind)
        var station = stations[key] ?? APRSStation(id: key, nameKey: Self.key(name), name: name, kind: kind,
                                                   firstHeard: time, lastHeard: time)
        station.name = name
        // Pakete können ausser der Reihe eintreffen (Wiedergabe, Verzögerung).
        station.lastHeard = max(station.lastHeard, time)
        change(&station)
        stations[key] = station
        return key
    }

    private mutating func update(_ key: String, _ change: (inout APRSStation) -> Void) {
        guard var station = stations[key] else { return }
        change(&station)
        stations[key] = station
    }

    private mutating func evictIfNeeded(keeping: Set<String>) {
        while stations.count > maxStations {
            guard let oldest = stations.values
                .filter({ !keeping.contains($0.id) })
                .min(by: { $0.lastHeard < $1.lastHeard }) else { return }
            stations[oldest.id] = nil
        }
    }
}

extension APRSStation {
    fileprivate mutating func apply(_ report: APRSPositionReport, at time: Date,
                                   limits: APRSStationTable.TrackLimits) {
        symbolTable = report.symbolTable
        symbolCode = report.symbolCode
        supportsMessaging = report.supportsMessaging
        comment = report.comment
        course = report.course
        speedKnots = report.speedKnots
        if let altitude = report.altitudeFeet { altitudeFeet = altitude }
        if let value = report.phg { phg = value }
        if let value = report.radioRangeMiles { radioRangeMiles = value }
        if let value = report.weather { weather = value }

        // Nullposition (0° N, 0° W) heisst «keine Position bekannt».
        guard report.latitude != 0 || report.longitude != 0 else { return }
        // Ein verspätet eintreffendes älteres Paket setzt die Station nicht zurück.
        if let last = lastPositionAt, time < last { return }

        let moved = track.last.map {
            abs($0.latitude - report.latitude) >= limits.minDelta
                || abs($0.longitude - report.longitude) >= limits.minDelta
        } ?? true
        latitude = report.latitude
        longitude = report.longitude
        ambiguity = report.ambiguity
        lastPositionAt = time
        if moved {
            track.append(APRSTrackPoint(latitude: report.latitude, longitude: report.longitude, time: time))
            if track.count > limits.maxPoints {
                track.removeFirst(track.count - limits.maxPoints)
            }
        }
    }
}
