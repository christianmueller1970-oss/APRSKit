import Foundation

extension APRSStation {
    /// q-Konstrukt aus dem Pfad des letzten Pakets (`qAR`, `qAC`, `qAO` …):
    /// sagt, wie das Paket in APRS-IS gelangt ist.
    public var qConstruct: String? {
        lastPath.first { $0.name.count == 3 && $0.name.hasPrefix("q") }?.name
    }

    /// Station hinter dem q-Konstrukt: das iGate bzw. der Server, der das
    /// Paket eingespeist hat.
    public var gateway: String? {
        guard let index = lastPath.firstIndex(where: { $0.name.count == 3 && $0.name.hasPrefix("q") }),
              index + 1 < lastPath.count else { return nil }
        return lastPath[index + 1].name
    }

    /// Digipeater, über die das letzte Paket auf Funk gelaufen ist. Im
    /// TNC2-Format trägt meist nur der letzte benutzte Eintrag den `*`; alle
    /// davor gelten ebenfalls als benutzt.
    public var usedDigipeaters: [String] {
        let radioPath = lastPath.prefix { !($0.name.count == 3 && $0.name.hasPrefix("q")) }
        guard let last = radioPath.lastIndex(where: \.isUsed) else { return [] }
        return radioPath[...last].map(\.name).filter { $0 != "TCPIP" }
    }

    /// Direkt ins Internet eingespeist, ohne Funkstrecke (`TCPIP*` im Pfad).
    public var isInternetOnly: Bool {
        lastPath.contains { $0.name == "TCPIP" || $0.name == "TCPXX" }
    }
}

/// Grosskreis-Rechnung auf der Kugel — genau genug für Liste und Sortierung.
public enum APRSGeo {
    public static func distanceKm(fromLatitude lat1: Double, longitude lon1: Double,
                                  toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let p = Double.pi / 180
        let h = pow(sin((lat2 - lat1) * p / 2), 2)
            + cos(lat1 * p) * cos(lat2 * p) * pow(sin((lon2 - lon1) * p / 2), 2)
        return 2 * 6371.0 * asin(min(1, sqrt(h)))
    }

    /// Anfangspeilung 0…360°, 0 = Nord, im Uhrzeigersinn.
    public static func bearingDegrees(fromLatitude lat1: Double, longitude lon1: Double,
                                      toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let p = Double.pi / 180
        let y = sin((lon2 - lon1) * p) * cos(lat2 * p)
        let x = cos(lat1 * p) * sin(lat2 * p) - sin(lat1 * p) * cos(lat2 * p) * cos((lon2 - lon1) * p)
        return (atan2(y, x) / p + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Eine Zeile der Stationsliste: Station plus Distanz und Peilung vom eigenen QTH.
public struct APRSStationRow: Equatable, Identifiable, Sendable {
    public let station: APRSStation
    /// nil ohne eigenes QTH oder ohne Position der Station.
    public let distanceKm: Double?
    public let bearingDegrees: Double?

    public var id: String { station.id }
}

/// Filter und Sortierung der Stationsliste. Reiner Werttyp.
public struct APRSStationQuery: Equatable, Sendable {
    public enum SortKey: String, CaseIterable, Sendable {
        case name
        case distance
        case lastHeard
        case packets
    }

    /// Leere Menge = alle Kategorien.
    public var categories: Set<APRSStationCategory> = []
    /// Nur, was der eigene Empfänger über Funk gehört hat.
    public var radioOnly = false
    /// Sucht in Name, Kommentar und Status, ohne Gross-/Kleinschreibung.
    public var search = ""
    public var sortKey: SortKey = .lastHeard
    public var ascending = false
    public var homeLatitude: Double?
    public var homeLongitude: Double?

    public init() {}

    /// Station zu einer Sucheingabe: genauer Name vor Namensanfang vor
    /// Namensteil; bei mehreren Treffern die zuletzt gehörte. Ohne
    /// Gross-/Kleinschreibung. nil bei leerer Eingabe oder ohne Treffer.
    public static func bestMatch(for text: String, in stations: [APRSStation],
                                 requiringPosition: Bool = false) -> APRSStation? {
        let needle = APRSStationTable.key(text)
        guard !needle.isEmpty else { return nil }
        var best: (rank: Int, station: APRSStation)?
        for station in stations where !requiringPosition || station.hasPosition {
            let rank: Int
            if station.nameKey == needle {
                rank = 0
            } else if station.nameKey.hasPrefix(needle) {
                rank = 1
            } else if station.nameKey.contains(needle) {
                rank = 2
            } else {
                continue
            }
            if let current = best,
               (current.rank, -current.station.lastHeard.timeIntervalSince1970, current.station.id)
                <= (rank, -station.lastHeard.timeIntervalSince1970, station.id) {
                continue
            }
            best = (rank, station)
        }
        return best?.station
    }

    public func rows(from stations: [APRSStation]) -> [APRSStationRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [APRSStationRow] = []
        rows.reserveCapacity(stations.count)
        for station in stations {
            if !categories.isEmpty, !categories.contains(station.category) { continue }
            if radioOnly, station.lastHeardOnRadio == nil { continue }
            if !needle.isEmpty,
               !station.name.lowercased().contains(needle),
               !station.comment.lowercased().contains(needle),
               !station.status.lowercased().contains(needle) { continue }
            var distance: Double?
            var bearing: Double?
            if let homeLat = homeLatitude, let homeLon = homeLongitude,
               let lat = station.latitude, let lon = station.longitude {
                distance = APRSGeo.distanceKm(fromLatitude: homeLat, longitude: homeLon,
                                              toLatitude: lat, longitude: lon)
                bearing = APRSGeo.bearingDegrees(fromLatitude: homeLat, longitude: homeLon,
                                                 toLatitude: lat, longitude: lon)
            }
            rows.append(APRSStationRow(station: station, distanceKm: distance, bearingDegrees: bearing))
        }
        return rows.sorted(by: areInOrder)
    }

    /// Stationen ohne Distanz stehen bei der Distanz-Sortierung immer am Ende;
    /// bei Gleichstand entscheidet der Schlüssel, damit die Reihenfolge stabil bleibt.
    private func areInOrder(_ a: APRSStationRow, _ b: APRSStationRow) -> Bool {
        switch sortKey {
        case .name:
            if a.station.nameKey != b.station.nameKey {
                return ascending ? a.station.nameKey < b.station.nameKey : a.station.nameKey > b.station.nameKey
            }
        case .distance:
            switch (a.distanceKm, b.distanceKm) {
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?):
                if x != y { return ascending ? x < y : x > y }
            }
        case .lastHeard:
            if a.station.lastHeard != b.station.lastHeard {
                return ascending ? a.station.lastHeard < b.station.lastHeard
                                 : a.station.lastHeard > b.station.lastHeard
            }
        case .packets:
            if a.station.packetCount != b.station.packetCount {
                return ascending ? a.station.packetCount < b.station.packetCount
                                 : a.station.packetCount > b.station.packetCount
            }
        }
        return a.station.id < b.station.id
    }
}
