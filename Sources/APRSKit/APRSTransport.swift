import Foundation

/// Weg eines Pakets: über APRS-IS (Internet) oder über das Funkgerät.
public enum APRSTransport: String, Codable, Sendable, CaseIterable {
    case internet
    case radio
}
