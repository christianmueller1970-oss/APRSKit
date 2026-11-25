import XCTest
@testable import APRSKit

final class APRSStationQueryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func table(_ lines: [String]) -> APRSStationTable {
        var table = APRSStationTable()
        for (index, line) in lines.enumerated() {
            guard let packet = try? APRSParser.parse(line) else {
                XCTFail("Paket nicht lesbar: \(line)")
                continue
            }
            table.ingest(packet, receivedAt: t0.addingTimeInterval(Double(index)))
        }
        return table
    }

    private var sample: [APRSStation] {
        Array(table([
            "N0FAR>APRS,TCPIP*,qAC,T2TEST:!4800.00N/00900.00E-Haus weit weg",
            "N0NEAR>APRS,WIDE1-1,WIDE2-1*,qAR,N0GATE:!4730.00N/00830.00E>088/036 Mobil",
            "N0WX>APRS,qAO,N0GATE:!4740.00N/00840.00E_220/004g005t077",
            "N0TEXT>APRS,qAS,N0GATE:>nur Status, QRV 145.500",
            "N0NEAR>APRS,WIDE1-1*,qAR,N0GATE:>unterwegs"
        ]).stations.values)
    }

    // MARK: - Pfad

    func testPathHelpers() {
        let stations = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
        XCTAssertEqual(stations["N0FAR"]?.qConstruct, "qAC")
        XCTAssertEqual(stations["N0FAR"]?.gateway, "T2TEST")
        XCTAssertEqual(stations["N0FAR"]?.usedDigipeaters, [])
        XCTAssertEqual(stations["N0FAR"]?.isInternetOnly, true)
        // Letztes Paket von N0NEAR: nur WIDE1-1 benutzt.
        XCTAssertEqual(stations["N0NEAR"]?.usedDigipeaters, ["WIDE1-1"])
        XCTAssertEqual(stations["N0NEAR"]?.gateway, "N0GATE")
        XCTAssertEqual(stations["N0NEAR"]?.isInternetOnly, false)
        XCTAssertEqual(stations["N0WX"]?.usedDigipeaters, [])
        XCTAssertEqual(stations["N0WX"]?.qConstruct, "qAO")
    }

    func testUsedDigipeatersIncludeEntriesBeforeTheStar() {
        let station = table(["N0CALL>APRS,N0DIGI,WIDE1,N0DIGI2*,WIDE2-1,qAR,N0GATE:>x"]).stations["N0CALL"]
        XCTAssertEqual(station?.usedDigipeaters, ["N0DIGI", "WIDE1", "N0DIGI2"])
        let none = table(["N0CALL>APRS:>x"]).stations["N0CALL"]
        XCTAssertNil(none?.qConstruct)
        XCTAssertNil(none?.gateway)
        let dangling = table(["N0CALL>APRS,qAR:>x"]).stations["N0CALL"]
        XCTAssertNil(dangling?.gateway)
    }

    // MARK: - Geometrie

    func testDistanceAndBearing() {
        // Ein Breitengrad sind rund 111,2 km; genau nach Norden.
        XCTAssertEqual(APRSGeo.distanceKm(fromLatitude: 47, longitude: 8, toLatitude: 48, longitude: 8),
                       111.19, accuracy: 0.05)
        XCTAssertEqual(APRSGeo.bearingDegrees(fromLatitude: 47, longitude: 8, toLatitude: 48, longitude: 8),
                       0, accuracy: 1e-6)
        XCTAssertEqual(APRSGeo.bearingDegrees(fromLatitude: 0, longitude: 8, toLatitude: 0, longitude: 9),
                       90, accuracy: 1e-6)
        XCTAssertEqual(APRSGeo.bearingDegrees(fromLatitude: 47, longitude: 8, toLatitude: 46, longitude: 8),
                       180, accuracy: 1e-6)
        XCTAssertEqual(APRSGeo.distanceKm(fromLatitude: 47, longitude: 8, toLatitude: 47, longitude: 8), 0)
        // Gegenpunkte: halber Erdumfang, ohne NaN.
        XCTAssertEqual(APRSGeo.distanceKm(fromLatitude: 0, longitude: 0, toLatitude: 0, longitude: 180),
                       20015.1, accuracy: 0.1)
    }

    // MARK: - Liste

    func testDefaultSortsNewestFirstWithoutHome() {
        let rows = APRSStationQuery().rows(from: sample)
        XCTAssertEqual(rows.map(\.id), ["N0NEAR", "N0TEXT", "N0WX", "N0FAR"])
        XCTAssertTrue(rows.allSatisfy { $0.distanceKm == nil && $0.bearingDegrees == nil })
    }

    func testDistanceSortKeepsStationsWithoutPositionLast() {
        var query = APRSStationQuery()
        query.homeLatitude = 47.5
        query.homeLongitude = 8.5
        query.sortKey = .distance
        query.ascending = true
        var rows = query.rows(from: sample)
        XCTAssertEqual(rows.map(\.id), ["N0NEAR", "N0WX", "N0FAR", "N0TEXT"])
        XCTAssertEqual(rows[0].distanceKm ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(rows[3].distanceKm)
        query.ascending = false
        rows = query.rows(from: sample)
        XCTAssertEqual(rows.map(\.id), ["N0FAR", "N0WX", "N0NEAR", "N0TEXT"])
    }

    func testSortByNameAndPackets() {
        var query = APRSStationQuery()
        query.sortKey = .name
        query.ascending = true
        XCTAssertEqual(query.rows(from: sample).map(\.id), ["N0FAR", "N0NEAR", "N0TEXT", "N0WX"])
        query.ascending = false
        XCTAssertEqual(query.rows(from: sample).map(\.id), ["N0WX", "N0TEXT", "N0NEAR", "N0FAR"])
        query.sortKey = .packets
        XCTAssertEqual(query.rows(from: sample).map(\.id).first, "N0NEAR")
    }

    func testCategoryAndSearchFilters() {
        var query = APRSStationQuery()
        query.sortKey = .name
        query.ascending = true
        query.categories = [.weather, .moving]
        XCTAssertEqual(query.rows(from: sample).map(\.id), ["N0NEAR", "N0WX"])
        query.categories = []
        query.search = "  qrv "
        XCTAssertEqual(query.rows(from: sample).map(\.id), ["N0TEXT"])
        query.search = "n0w"
        XCTAssertEqual(query.rows(from: sample).map(\.id), ["N0WX"])
        query.search = "HAUS"
        XCTAssertEqual(query.rows(from: sample).map(\.id), ["N0FAR"])
        query.search = "gibt es nicht"
        XCTAssertEqual(query.rows(from: sample), [])
    }

    // MARK: - Suche

    func testBestMatchPrefersExactThenPrefixThenContains() {
        let stations = Array(table([
            "HB9ABC-9>APRS:!4730.00N/00830.00E>",
            "HB9ABC>APRS:!4731.00N/00831.00E-",
            "DB0HB9>APRS:!4732.00N/00832.00E#",
            "HB9XYZ>APRS:>nur Status"
        ]).stations.values)
        func match(_ text: String, position: Bool = false) -> String? {
            APRSStationQuery.bestMatch(for: text, in: stations.shuffled(), requiringPosition: position)?.id
        }
        XCTAssertEqual(match(" hb9abc "), "HB9ABC")          // genau, trotz Leerzeichen und Kleinschreibung
        XCTAssertEqual(match("HB9ABC-9"), "HB9ABC-9")
        XCTAssertEqual(match("HB9A"), "HB9ABC")              // Anfang: zuletzt gehörte zuerst
        XCTAssertEqual(match("0HB"), "DB0HB9")               // nur als Teil enthalten
        XCTAssertEqual(match("HB9"), "HB9XYZ")               // Anfang schlägt Teil, neueste gewinnt
        XCTAssertEqual(match("HB9", position: true), "HB9ABC")
        XCTAssertNil(match("HB9XYZ", position: true))        // ohne Position nicht auf der Karte
        XCTAssertNil(match(""))
        XCTAssertNil(match("   "))
        XCTAssertNil(match("OE1"))
    }

    /// Objekte tragen im Schlüssel ein Vorzeichen; gesucht und sortiert wird nach dem Namen.
    func testObjectsAreFoundAndSortedByName() {
        let stations = Array(table([
            "N0CALL>APRS:;LEADER   *092345z4903.50N/07201.75W>",
            "N0ZZZ>APRS:!4730.00N/00830.00E-",
            "N0CALL>APRS:)AID #2!4903.50N/07201.75WA"
        ]).stations.values)
        XCTAssertEqual(APRSStationQuery.bestMatch(for: "leader", in: stations)?.id, ";LEADER")
        XCTAssertEqual(APRSStationQuery.bestMatch(for: "aid", in: stations)?.id, ")AID #2")
        var query = APRSStationQuery()
        query.sortKey = .name
        query.ascending = true
        XCTAssertEqual(query.rows(from: stations).map(\.station.name), ["AID #2", "LEADER", "N0CALL", "N0ZZZ"])
        query.ascending = false
        XCTAssertEqual(query.rows(from: stations).map(\.station.name), ["N0ZZZ", "N0CALL", "LEADER", "AID #2"])
    }

    func testBestMatchIsDeterministicForEqualTimes() {
        var table = APRSStationTable()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for call in ["N0BB", "N0BA", "N0BC"] {
            table.ingest(try! APRSParser.parse("\(call)>APRS:>x"), receivedAt: now)
        }
        for _ in 0..<5 {
            XCTAssertEqual(APRSStationQuery.bestMatch(for: "N0B", in: Array(table.stations.values).shuffled())?.id, "N0BA")
        }
    }

    func testOrderIsStableForEqualValues() {
        let stations = Array(table(["N0B>APRS:>x", "N0A>APRS:>x", "N0C>APRS:>x"]).stations.values)
        var query = APRSStationQuery()
        query.sortKey = .packets
        for _ in 0..<5 {
            XCTAssertEqual(query.rows(from: stations.shuffled()).map(\.id), ["N0A", "N0B", "N0C"])
        }
    }

    func testRadioOnlyKeepsOnlyStationsHeardByOwnReceiver() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var table = APRSStationTable()
        table.ingest(try APRSParser.parse("N0NET>APRS,TCPIP*,qAC,T2TEST:=4903.50N/07201.75W-"), receivedAt: t0)
        table.ingest(try APRSParser.parse("N0RF>APRS,WIDE1-1:=4903.50N/07201.75W>"), receivedAt: t0, transport: .radio)
        var query = APRSStationQuery()
        XCTAssertEqual(query.rows(from: Array(table.stations.values)).count, 2)
        query.radioOnly = true
        XCTAssertEqual(query.rows(from: Array(table.stations.values)).map(\.station.name), ["N0RF"])
    }
}
