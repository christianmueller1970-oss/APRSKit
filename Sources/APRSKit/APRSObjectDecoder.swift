import Foundation

/// Objekte (`;NAME_____*DDHHMMzPosition`) und Items (`)NAME!Position`).
enum APRSObjectDecoder {
    private static let objectNameLength = 9
    private static let timestampLength = 7
    private static let itemNameRange = 3...9

    static func decodeObject(_ payload: ArraySlice<UInt8>) -> APRSObjectReport? {
        var rest = payload.dropFirst()
        guard rest.count > objectNameLength + timestampLength else { return nil }
        let nameBytes = rest.prefix(objectNameLength)
        rest = rest.dropFirst(objectNameLength)
        guard let isLive = liveFlag(rest[rest.startIndex], live: UInt8(ascii: "*")) else { return nil }
        rest = rest.dropFirst()
        let timestamp = APRSPositionDecoder.decodeTimestamp(rest.prefix(timestampLength))
        rest = rest.dropFirst(timestampLength)
        return report(nameBytes, isLive: isLive, timestamp: timestamp, body: rest)
    }

    static func decodeItem(_ payload: ArraySlice<UInt8>) -> APRSObjectReport? {
        let rest = payload.dropFirst()
        // Der Name endet am ersten `!` (aktiv) oder `_` (gelöscht).
        guard let end = rest.firstIndex(where: { $0 == UInt8(ascii: "!") || $0 == UInt8(ascii: "_") }),
              itemNameRange.contains(rest.distance(from: rest.startIndex, to: end)),
              let isLive = liveFlag(rest[end], live: UInt8(ascii: "!")) else { return nil }
        return report(rest[rest.startIndex..<end], isLive: isLive, timestamp: nil,
                      body: rest[rest.index(after: end)...])
    }

    private static func liveFlag(_ byte: UInt8, live: UInt8) -> Bool? {
        if byte == live { return true }
        if byte == UInt8(ascii: "_") { return false }
        return nil
    }

    private static func report(_ nameBytes: ArraySlice<UInt8>, isLive: Bool,
                               timestamp: APRSTimestamp?, body: ArraySlice<UInt8>) -> APRSObjectReport? {
        guard nameBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let position = APRSPositionDecoder.decodeBody(body) else { return nil }
        let name = String(decoding: nameBytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !name.isEmpty else { return nil }
        return APRSObjectReport(
            name: name, isLive: isLive,
            position: APRSPositionDecoder.report(position, timestamp: timestamp, supportsMessaging: false))
    }
}
