import Foundation

/// Regel-Logik eines iGate in beide Richtungen. Reiner Werttyp ohne Uhr, Netz
/// und Funk: der Aufrufer reicht Pakete und Zeit herein und sendet, was
/// zurückkommt.
///
/// Regeln nach aprs-is.net («IGate Details» und «q-Konstrukt», gelesen am
/// 21.11.2026); die Zahlen (Fristen, Hops, Sendelast) sind Entscheide aus
/// `docs/plans/2026-11-21-aprs-igate.md`, die Quelle nennt keine.
public struct APRSIGate: Equatable, Sendable {

    /// Warum ein Paket nicht weitergereicht wurde.
    public enum SkipReason: String, Equatable, Sendable, CaseIterable {
        /// Eigenes Paket oder ungültiges iGate-Rufzeichen.
        case own
        /// Third-Party-Paket, das schon aus dem Internet stammt.
        case fromInternet
        /// `TCPIP`, `TCPXX`, `NOGATE` oder `RFONLY` im Pfad.
        case pathMarker
        /// Allgemeine Abfrage (Datentyp `?`).
        case query
        /// Gleiche Quelle und Nutzdaten kurz zuvor schon weitergereicht.
        case duplicate
        /// Kopf nicht darstellbar.
        case malformed
        /// Kein an eine Station gerichteter Inhalt (nur Internet → Funk).
        case notEligible
        /// Empfänger nicht kürzlich lokal über Funk gehört.
        case recipientNotLocal
        /// Empfänger kürzlich über das Internet gehört (oder selbst iGate).
        case recipientOnInternet
        /// Absender kürzlich selbst über Funk gehört — er erreicht den Empfänger direkt.
        case senderOnRadio
        /// Sendelast-Grenze erreicht.
        case rateLimited
    }

    public enum Decision: Equatable, Sendable {
        /// Weiterreichen: fertige Zeile (Funk → Internet) bzw. Nutzdaten des
        /// Third-Party-Pakets (Internet → Funk).
        case gate([UInt8])
        case skip(SkipReason)
    }

    // MARK: Grenzen (Entscheide I2–I4)

    /// Gleiche Quelle und Nutzdaten gelten so lange als Duplikat.
    public static let duplicateWindow: TimeInterval = 30
    /// «Lokal gehört»: so lange zurück, über höchstens `maxLocalHops` Digipeater.
    public static let localWindow: TimeInterval = 3_600
    public static let maxLocalHops = 1
    /// Die Position eines Absenders höchstens einmal in dieser Zeit auf Funk.
    public static let positionSpacing: TimeInterval = 1_800
    /// Sendelast Internet → Funk.
    public static let maxPerMinute = 6
    public static let maxPerHour = 60

    private var recentToInternet: [[UInt8]: Date] = [:]
    /// Zeitpunkte der auf Funk gereichten Pakete (für die Sendelast).
    private var sentToRadio: [Date] = []
    /// Absender, deren nächste Position mit auf Funk darf (Zeit der Message).
    private var positionWanted: [String: Date] = [:]
    private var positionSent: [String: Date] = [:]

    public init() {}

    // MARK: - Funk → Internet

    /// Entscheidet über ein vom eigenen Empfänger gehörtes Paket. `line` ist die
    /// empfangene TNC2-Zeile; ihr Kopf bleibt unverändert, angehängt wird nur
    /// `,qAR,<igate>` — bzw. `,qAO,…`, wenn dieses iGate nicht auf Funk sendet.
    public mutating func gateToInternet(line: [UInt8], packet: APRSPacket, igate: String,
                                        transmitsToRadio: Bool, receivedAt: Date) -> Decision {
        let me = APRSStationTable.key(igate)
        guard APRSIS.isValidLoginCallsign(me) else { return .skip(.own) }

        // Third-Party: stammt der innere Kopf aus dem Internet, nicht zurückreichen;
        // sonst äusseren Funk-Kopf und `}` entfernen und das innere Paket nehmen.
        var subject = packet
        var subjectLine = line
        // Internet-Marker im äusseren Pfad gelten auch für ein eingepacktes
        // Paket: sonst ginge der Herkunftsvermerk beim Auspacken verloren
        // (Codex-Review 21.11.2026).
        guard !Self.hasInternetMarker(packet.path) else { return .skip(.pathMarker) }
        if case .thirdParty(let inner) = packet.content {
            guard !Self.hasInternetMarker(inner.path) else { return .skip(.fromInternet) }
            subject = inner
            subjectLine = Array(packet.payload.dropFirst())
        }
        guard subject.sourceKey != me, packet.sourceKey != me else { return .skip(.own) }
        guard !Self.hasInternetMarker(subject.path), !Self.hasNoGateMarker(subject.path),
              !Self.hasNoGateMarker(packet.path) else { return .skip(.pathMarker) }
        guard subject.dataTypeIdentifier != UInt8(ascii: "?") else { return .skip(.query) }
        guard let colon = subjectLine.firstIndex(of: UInt8(ascii: ":")), colon > 0,
              !subject.payload.isEmpty,
              // Zeilenenden im Paket würden auf APRS-IS eine zweite Zeile einschleusen.
              !subjectLine.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return .skip(.malformed) }

        // Direkt und über Digipeater gehörte Kopien desselben Pakets nur einmal.
        recentToInternet = recentToInternet.filter { receivedAt.timeIntervalSince($0.value) < Self.duplicateWindow }
        let key = Array(subject.sourceKey.utf8) + [0] + subject.payload
        guard recentToInternet[key] == nil else { return .skip(.duplicate) }
        recentToInternet[key] = receivedAt

        let construct = transmitsToRadio ? "qAR" : "qAO"
        return .gate(Array(subjectLine[..<colon]) + Array(",\(construct),\(me)".utf8) + Array(subjectLine[colon...]))
    }

    // MARK: - Internet → Funk

    /// Entscheidet über ein von APRS-IS empfangenes Paket. Liefert die
    /// Nutzdaten für die eigene Aussendung im Third-Party-Format
    /// `}ABSENDER>ZIEL,TCPIP,<igate>*:Nutzdaten`; APRS-IS-Pfad und q-Konstrukt
    /// entfallen. `station` schlägt eine Station im Stationsspeicher nach.
    public mutating func gateToRadio(_ packet: APRSPacket, igate: String, receivedAt: Date,
                                     station: (String) -> APRSStation?) -> Decision {
        let me = APRSStationTable.key(igate)
        guard APRSIS.isValidLoginCallsign(me), packet.sourceKey != me else { return .skip(.own) }
        let sender = packet.sourceKey

        let isPosition: Bool
        switch packet.content {
        case .message(let message):
            // Bulletins und Rundmeldungen sind an niemanden gerichtet.
            guard !message.isBulletin else { return .skip(.notEligible) }
            let recipient = message.addresseeKey
            guard recipient != me, !recipient.isEmpty else { return .skip(.own) }
            // 1. Empfänger kürzlich lokal über Funk gehört, nah genug.
            guard let target = station(recipient), let heard = target.lastHeardOnRadio,
                  receivedAt.timeIntervalSince(heard) < Self.localWindow,
                  (target.lastRadioHops ?? .max) <= Self.maxLocalHops else { return .skip(.recipientNotLocal) }
            // 4. Empfänger nicht kürzlich über das Internet gehört.
            if let online = target.lastHeardViaInternet,
               receivedAt.timeIntervalSince(online) < Self.localWindow { return .skip(.recipientOnInternet) }
            isPosition = false
        case .position:
            // Nur die Position zu einer eben weitergereichten Message, höchstens einmal je Frist.
            guard let wanted = positionWanted[sender],
                  receivedAt.timeIntervalSince(wanted) < Self.positionSpacing else { return .skip(.notEligible) }
            if let last = positionSent[sender],
               receivedAt.timeIntervalSince(last) < Self.positionSpacing { return .skip(.notEligible) }
            isPosition = true
        default:
            return .skip(.notEligible)
        }

        // 3. Absender will nicht auf Funk bzw. ist nicht vertrauenswürdig angemeldet.
        guard !packet.path.contains(where: { ["TCPXX", "NOGATE", "RFONLY"].contains($0.name.uppercased()) }) else {
            return .skip(.pathMarker)
        }
        // 2. Absender nicht selbst kürzlich über Funk gehört.
        if let heard = station(sender)?.lastHeardOnRadio,
           receivedAt.timeIntervalSince(heard) < Self.localWindow { return .skip(.senderOnRadio) }

        // Nutzdaten müssen als Text auf Funk darstellbar sein.
        guard !packet.payload.isEmpty, packet.payload.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }),
              !sender.isEmpty, !packet.destination.isEmpty else { return .skip(.malformed) }

        // Sendelast: gezählt wird, was wirklich weitergereicht wird.
        sentToRadio.removeAll { receivedAt.timeIntervalSince($0) >= 3_600 }
        guard sentToRadio.count < Self.maxPerHour,
              sentToRadio.filter({ receivedAt.timeIntervalSince($0) < 60 }).count < Self.maxPerMinute else {
            return .skip(.rateLimited)
        }
        sentToRadio.append(receivedAt)
        if isPosition {
            positionSent[sender] = receivedAt
            positionWanted[sender] = nil
        } else {
            positionWanted[sender] = receivedAt
        }
        positionWanted = positionWanted.filter { receivedAt.timeIntervalSince($0.value) < Self.positionSpacing }
        positionSent = positionSent.filter { receivedAt.timeIntervalSince($0.value) < Self.positionSpacing }

        let header = "}\(sender)>\(packet.destination.uppercased()),TCPIP,\(me)*:"
        return .gate(Array(header.utf8) + packet.payload)
    }

    // MARK: - Intern

    private static func hasInternetMarker(_ path: [APRSPathElement]) -> Bool {
        path.contains { ["TCPIP", "TCPXX"].contains($0.name.uppercased()) }
    }

    private static func hasNoGateMarker(_ path: [APRSPathElement]) -> Bool {
        path.contains { ["NOGATE", "RFONLY"].contains($0.name.uppercased()) }
    }
}
