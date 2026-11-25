import Foundation

/// Eine eigene, gesendete Message samt Zustellstand.
public struct APRSOutgoingMessage: Equatable, Identifiable, Codable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Gesendet, Bestätigung steht aus; wird noch wiederholt.
        case pending
        case acknowledged
        /// Die Gegenstation hat mit `rej` abgelehnt.
        case rejected
        /// Alle Versuche ohne Bestätigung — nicht «gescheitert»: die Message
        /// kann angekommen sein, nur das Ack fehlt.
        case unconfirmed
    }

    public let id: UUID
    /// Adressat, wie eingegeben (Grossbuchstaben).
    public let to: String
    public let text: String
    public let messageID: String
    public let createdAt: Date
    public var attempts: Int
    public var lastAttemptAt: Date
    public var state: State
    /// Weg, auf dem gesendet und wiederholt wird. nil in Verläufen von vor
    /// dem Funkbetrieb: gilt als Internet.
    public var transport: APRSTransport?

    public var route: APRSTransport { transport ?? .internet }
}

public struct APRSIncomingMessage: Equatable, Identifiable, Codable, Sendable {
    public let id: UUID
    public let from: String
    public let text: String
    /// nil: die Gegenstation erwartet keine Bestätigung.
    public let messageID: String?
    public let receivedAt: Date
    /// Weg, auf dem die Message ankam (beim ersten Empfang). nil in älteren Verläufen.
    public var transport: APRSTransport?
}

/// Bulletin oder Announcement (`BLN…`); je Absender und Kennung der letzte Text.
public struct APRSBulletin: Equatable, Identifiable, Codable, Sendable {
    public var id: String { from + "|" + name }
    public let from: String
    public let name: String
    public var text: String
    public var receivedAt: Date
}

/// Zustandslogik des Messagings: Laufnummern, Wiederholungen, Bestätigungen
/// und Duplikate. Reiner Werttyp ohne Uhr und ohne Netz — der Aufrufer reicht
/// die Zeit herein und sendet die gelieferten Nutzdaten.
public struct APRSMessageCenter: Equatable, Codable, Sendable {
    /// Wartezeit nach dem 1., 2., … Versuch. Nach dem letzten Eintrag gilt die
    /// Message als unbestätigt (Entscheid Chris 21.11.2026, Werte des Konzepts).
    ///
    /// Der erste Abstand ist 45 s statt 30 s: APRS-IS verwirft ein Paket mit
    /// gleichem Absender und Inhalt als Duplikat, wenn es innert rund 30 s
    /// erneut kommt. Beobachtet am 21.11.2026 — von den Versuchen bei 0, +30,
    /// +90 und +210 s kam der bei +30 s auf einer zweiten Verbindung nie an.
    public static let retryDelays: [TimeInterval] = [45, 60, 120, 240, 480]
    public static let maxMessages = 2_000
    public static let maxBulletins = 200
    /// So lange gilt eine wiederholte Message mit gleicher Nummer und gleichem
    /// Text als Duplikat.
    public static let duplicateWindow: TimeInterval = 24 * 3600

    public private(set) var outgoing: [APRSOutgoingMessage] = []
    public private(set) var incoming: [APRSIncomingMessage] = []
    public private(set) var bulletins: [APRSBulletin] = []
    private var nextNumber = 1

    public init() {}

    public struct ReceiveResult: Equatable, Sendable {
        /// Nutzdaten, die jetzt zu senden sind (Bestätigungen).
        public var payloads: [String] = []
        /// Neu anzuzeigende Message (nicht bei Duplikaten).
        public var newMessage: APRSIncomingMessage?
        public var newBulletin: APRSBulletin?
        /// Irgendetwas am Stand hat sich geändert (auch Zustellstand).
        public var changed = false
    }

    // MARK: - Senden

    /// Legt eine neue Message an und liefert die Nutzdaten des ersten Versuchs.
    /// nil, wenn Adressat oder Text nicht sendbar sind. Wiederholungen bleiben
    /// auf `transport`.
    public mutating func compose(to addressee: String, text: String, now: Date,
                                 transport: APRSTransport = .internet) -> String? {
        let to = APRSStationTable.key(addressee)
        let number = String(nextNumber)
        let cleaned = APRSEncoder.messageText(text)
        guard let payload = APRSEncoder.message(to: to, text: cleaned, messageID: number) else { return nil }
        nextNumber = nextNumber >= 99_999 ? 1 : nextNumber + 1
        outgoing.append(APRSOutgoingMessage(id: UUID(), to: to, text: cleaned, messageID: number,
                                            createdAt: now, attempts: 1, lastAttemptAt: now, state: .pending,
                                            transport: transport))
        trim()
        return payload
    }

    /// Fällige Wiederholungen auf einem Weg. Nach dem letzten Versuch und
    /// Ablauf der letzten Wartezeit wird die Message «unbestätigt». Gerechnet
    /// wird gegen `now`.
    public mutating func due(now: Date, on transport: APRSTransport = .internet) -> [String] {
        var payloads: [String] = []
        for index in outgoing.indices
        where outgoing[index].state == .pending && outgoing[index].route == transport {
            let message = outgoing[index]
            let delay = Self.retryDelays[min(message.attempts, Self.retryDelays.count) - 1]
            guard now.timeIntervalSince(message.lastAttemptAt) >= delay else { continue }
            if message.attempts >= Self.retryDelays.count {
                outgoing[index].state = .unconfirmed
            } else if let payload = APRSEncoder.message(to: message.to, text: message.text,
                                                        messageID: message.messageID) {
                outgoing[index].attempts += 1
                outgoing[index].lastAttemptAt = now
                payloads.append(payload)
            }
        }
        return payloads
    }

    /// Unbestätigte oder abgelehnte Message von Hand erneut senden: die
    /// Versuche beginnen von vorn, die Laufnummer bleibt. Mit `transport`
    /// wechselt der Weg (gilt dann auch für die Wiederholungen).
    public mutating func resend(_ id: UUID, now: Date, transport: APRSTransport? = nil) -> String? {
        guard let index = outgoing.firstIndex(where: { $0.id == id }),
              outgoing[index].state == .unconfirmed || outgoing[index].state == .rejected,
              let payload = APRSEncoder.message(to: outgoing[index].to, text: outgoing[index].text,
                                                messageID: outgoing[index].messageID) else { return nil }
        outgoing[index].state = .pending
        outgoing[index].attempts = 1
        outgoing[index].lastAttemptAt = now
        if let transport { outgoing[index].transport = transport }
        return payload
    }

    /// Stellt Wiederholungen ein, z. B. beim Trennen: Wartende werden
    /// «unbestätigt». Mit `transport` nur die auf diesem Weg, sonst alle.
    public mutating func stopRetrying(on transport: APRSTransport? = nil) {
        for index in outgoing.indices
        where outgoing[index].state == .pending && (transport == nil || outgoing[index].route == transport) {
            outgoing[index].state = .unconfirmed
        }
    }

    // MARK: - Empfangen

    /// Verarbeitet eine empfangene Message. `myCall` ist das eigene
    /// APRS-Rufzeichen samt SSID; nur genau daran Adressiertes wird bestätigt.
    /// Die gelieferten Bestätigungen gehören auf den Eingangsweg `transport`.
    public mutating func receive(_ message: APRSMessage, from source: String, myCall: String,
                                 now: Date, transport: APRSTransport = .internet) -> ReceiveResult {
        var result = ReceiveResult()
        let sender = APRSStationTable.key(source)
        let me = APRSStationTable.key(myCall)
        guard !sender.isEmpty else { return result }

        if message.isBulletin {
            guard message.kind == .text else { return result }
            let name = message.addresseeKey
            if let index = bulletins.firstIndex(where: { $0.from == sender && $0.name == name }) {
                guard bulletins[index].text != message.text else {
                    bulletins[index].receivedAt = now
                    return result
                }
                bulletins[index].text = message.text
                bulletins[index].receivedAt = now
                result.newBulletin = bulletins[index]
            } else {
                let bulletin = APRSBulletin(from: sender, name: name, text: message.text, receivedAt: now)
                bulletins.append(bulletin)
                if bulletins.count > Self.maxBulletins {
                    bulletins.removeFirst(bulletins.count - Self.maxBulletins)
                }
                result.newBulletin = bulletin
            }
            result.changed = true
            return result
        }

        // Fremde Gespräche und das eigene Echo gehen uns nichts an.
        guard !me.isEmpty, message.addresseeKey == me, sender != me else { return result }

        switch message.kind {
        case .ack:
            result.changed = settle(sender: sender, messageID: message.messageID, as: .acknowledged)
        case .reject:
            result.changed = settle(sender: sender, messageID: message.messageID, as: .rejected)
        case .text:
            // Reply-Ack: die Gegenstation bestätigt mit ihrer Message zugleich unsere.
            if settle(sender: sender, messageID: message.replyAckID, as: .acknowledged) {
                result.changed = true
            }
            // Jede Message mit Nummer wird bestätigt, auch ein Duplikat —
            // sonst wiederholt die Gegenstation weiter.
            if let id = message.messageID, let ack = APRSEncoder.ack(to: sender, messageID: id) {
                result.payloads.append(ack)
            }
            let isDuplicate = message.messageID != nil && incoming.contains {
                $0.from == sender && $0.messageID == message.messageID && $0.text == message.text
                    && now.timeIntervalSince($0.receivedAt) < Self.duplicateWindow
            }
            if !isDuplicate {
                let entry = APRSIncomingMessage(id: UUID(), from: sender, text: message.text,
                                                messageID: message.messageID, receivedAt: now,
                                                transport: transport)
                incoming.append(entry)
                trim()
                result.newMessage = entry
                result.changed = true
            }
        }
        return result
    }

    /// Entfernt den ganzen Verlauf mit einer Gegenstation.
    public mutating func removeConversation(with station: String) {
        let key = APRSStationTable.key(station)
        outgoing.removeAll { $0.to == key }
        incoming.removeAll { $0.from == key }
    }

    public mutating func removeBulletins() { bulletins.removeAll() }

    // MARK: - Intern

    /// Nur wartende und unbestätigte Messages lassen sich bestätigen oder ablehnen.
    private mutating func settle(sender: String, messageID: String?,
                                 as state: APRSOutgoingMessage.State) -> Bool {
        guard let messageID,
              let index = outgoing.lastIndex(where: {
                  $0.to == sender && $0.messageID == messageID
                      && ($0.state == .pending || $0.state == .unconfirmed)
              }) else { return false }
        outgoing[index].state = state
        return true
    }

    /// Älteste Einträge fallen weg; wartende eigene Messages bleiben.
    private mutating func trim() {
        if incoming.count > Self.maxMessages {
            incoming.removeFirst(incoming.count - Self.maxMessages)
        }
        var excess = outgoing.count - Self.maxMessages
        if excess > 0 {
            outgoing.removeAll { message in
                guard excess > 0, message.state != .pending else { return false }
                excess -= 1
                return true
            }
        }
    }
}
