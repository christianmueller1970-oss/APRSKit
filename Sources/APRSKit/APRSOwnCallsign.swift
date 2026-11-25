import Foundation

/// Welches Basis-Rufzeichen (ohne SSID) die eigene APRS-Station führt:
/// der Call des Operator-Profils oder ein anderer aus der Lizenz.
public enum APRSOwnCallsign {

    /// Basis-Rufzeichen: getrimmt, gross, ohne SSID.
    public static func base(_ call: String) -> String {
        call.trimmingCharacters(in: .whitespaces).uppercased()
            .split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// Auswahlliste: Profil-Call zuerst, dann die Lizenz-Calls; ohne Leere und Doppelte.
    public static func choices(profileCall: String, licensedCalls: [String]) -> [String] {
        var result: [String] = []
        for call in [profileCall] + licensedCalls {
            let normalized = base(call)
            if !normalized.isEmpty, !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

    /// Wirksames Basis-Rufzeichen. Die Auswahl gilt nur, solange sie in der
    /// Liste steht; sonst (leer, Lizenz gewechselt) gilt der Profil-Call.
    public static func effective(selected: String, profileCall: String, licensedCalls: [String]) -> String {
        let wanted = base(selected)
        if !wanted.isEmpty, choices(profileCall: profileCall, licensedCalls: licensedCalls).contains(wanted) {
            return wanted
        }
        return base(profileCall)
    }
}
