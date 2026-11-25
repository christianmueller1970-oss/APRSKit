import XCTest
@testable import APRSKit

final class APRSStationTableTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ingest(_ table: inout APRSStationTable, _ line: String, at seconds: TimeInterval = 0,
                        file: StaticString = #filePath, line l: UInt = #line) -> [String] {
        guard let packet = try? APRSParser.parse(line) else {
            XCTFail("Paket nicht lesbar: \(line)", file: file, line: l)
            return []
        }
        return table.ingest(packet, receivedAt: t0.addingTimeInterval(seconds))
    }

    func testPositionCreatesStation() {
        var table = APRSStationTable()
        let changed = ingest(&table, "n0call-9>APRS,WIDE1-1*,qAR,N0GATE:=4903.50N/07201.75W>088/036 unterwegs /A=001234")
        XCTAssertEqual(changed, ["N0CALL-9"])
        let station = table.stations["N0CALL-9"]
        XCTAssertEqual(station?.name, "n0call-9")
        XCTAssertEqual(station?.kind, .station)
        XCTAssertEqual(station?.latitude ?? 0, 49 + 3.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(station?.symbolCode, ">")
        XCTAssertEqual(station?.course, 88)
        XCTAssertEqual(station?.altitudeFeet, 1234)
        XCTAssertEqual(station?.supportsMessaging, true)
        XCTAssertEqual(station?.comment, " unterwegs ")
        XCTAssertEqual(station?.packetCount, 1)
        XCTAssertEqual(station?.lastPath.count, 3)
        XCTAssertEqual(station?.track.count, 1)
        XCTAssertEqual(station?.category, .moving)
        XCTAssertEqual(station?.firstHeard, t0)
    }

    func testTrackGrowsOnlyOnMovementAndIsCapped() {
        var table = APRSStationTable(maxTrackPoints: 3)
        _ = ingest(&table, "N0CALL>APRS:!4903.50N/07201.75W>", at: 0)
        _ = ingest(&table, "N0CALL>APRS:!4903.50N/07201.75W>", at: 60)      // steht
        XCTAssertEqual(table.stations["N0CALL"]?.track.count, 1)
        XCTAssertEqual(table.stations["N0CALL"]?.lastHeard, t0.addingTimeInterval(60))
        for (index, minutes) in ["51", "52", "53", "54"].enumerated() {
            _ = ingest(&table, "N0CALL>APRS:!4903.\(minutes)N/07201.75W>", at: Double(120 + index * 60))
        }
        let station = table.stations["N0CALL"]
        XCTAssertEqual(station?.track.count, 3)
        XCTAssertEqual(station?.track.last?.latitude ?? 0, 49 + 3.54 / 60, accuracy: 1e-9)
        XCTAssertEqual(station?.track.first?.latitude ?? 0, 49 + 3.52 / 60, accuracy: 1e-9)
        XCTAssertEqual(station?.packetCount, 6)
    }

    func testLatePacketDoesNotMoveStationBack() {
        var table = APRSStationTable()
        _ = ingest(&table, "N0CALL>APRS:!4903.60N/07201.75W>", at: 100)
        _ = ingest(&table, "N0CALL>APRS:!4903.50N/07201.75W>", at: 40)       // verspätet
        let station = table.stations["N0CALL"]
        XCTAssertEqual(station?.latitude ?? 0, 49 + 3.6 / 60, accuracy: 1e-9)
        XCTAssertEqual(station?.lastHeard, t0.addingTimeInterval(100))
        XCTAssertEqual(station?.track.count, 1)
        XCTAssertEqual(station?.packetCount, 2)
    }

    func testNullPositionIsNoPosition() {
        var table = APRSStationTable()
        _ = ingest(&table, "N0CALL>APRS:!0000.00N\\00000.00W.")
        XCTAssertEqual(table.stations["N0CALL"]?.hasPosition, false)
        XCTAssertEqual(table.stations["N0CALL"]?.track.count, 0)
        XCTAssertEqual(table.stations["N0CALL"]?.symbolCode, ".")
    }

    func testStatusWeatherTelemetryAndMessageKeepPosition() {
        var table = APRSStationTable()
        _ = ingest(&table, "N0CALL>APRS:!4903.50N/07201.75W-Haus", at: 0)
        _ = ingest(&table, "N0CALL>APRS:>QRV auf 145.500", at: 10)
        _ = ingest(&table, "N0CALL>APRS:T#005,199,000,255,073,123,01101001", at: 20)
        _ = ingest(&table, "N0CALL>APRS:_10090556c220s004g005t077", at: 30)
        _ = ingest(&table, "N0CALL>APRS::N0OTHER  :Hallo{1", at: 40)
        let station = table.stations["N0CALL"]
        XCTAssertEqual(station?.status, "QRV auf 145.500")
        XCTAssertEqual(station?.telemetry?.sequence, "005")
        XCTAssertEqual(station?.weather?.temperatureFahrenheit, 77)
        XCTAssertEqual(station?.hasPosition, true)
        XCTAssertEqual(station?.comment, "Haus")
        XCTAssertEqual(station?.packetCount, 5)
        XCTAssertEqual(station?.category, .weather)
        XCTAssertEqual(table.count, 1)   // der Adressat einer Message ist keine gehörte Station
    }

    func testObjectsItemsAndKill() {
        var table = APRSStationTable()
        let changed = ingest(&table, "N0CALL>APRS:;LEADER   *092345z4903.50N/07201.75W>088/036")
        XCTAssertEqual(changed, ["N0CALL", ";LEADER"])
        XCTAssertEqual(table.stations[";LEADER"]?.kind, .object)
        XCTAssertEqual(table.stations[";LEADER"]?.name, "LEADER")
        XCTAssertEqual(table.stations[";LEADER"]?.nameKey, "LEADER")
        XCTAssertEqual(table.stations[";LEADER"]?.owner, "N0CALL")
        XCTAssertEqual(table.stations[";LEADER"]?.category, .object)
        XCTAssertEqual(table.stations["N0CALL"]?.hasPosition, false)

        _ = ingest(&table, "N0CALL>APRS:)AID #2!4903.50N/07201.75WA", at: 5)
        XCTAssertEqual(table.stations[")AID #2"]?.kind, .item)

        _ = ingest(&table, "N0CALL>APRS:;LEADER   _092345z4903.50N/07201.75W>", at: 10)
        XCTAssertNil(table.stations[";LEADER"])
        _ = ingest(&table, "N0CALL>APRS:)AID #2_4903.50N/07201.75WA", at: 15)
        XCTAssertNil(table.stations[")AID #2"])
        XCTAssertEqual(table.count, 1)
    }

    /// Codex-Review 21.11.2026: ein Objekt oder Item, das wie eine Station heisst,
    /// überschreibt deren Eintrag nicht und löscht ihn mit «Kill» auch nicht.
    func testObjectWithStationNameLeavesStationAlone() {
        var table = APRSStationTable()
        _ = ingest(&table, "N0HOME>APRS:!4730.00N/00830.00E-Zuhause", at: 0)
        _ = ingest(&table, "N0OTHER>APRS:;N0HOME   *092345z4903.50N/07201.75W>fremdes Objekt", at: 10)
        _ = ingest(&table, "N0OTHER>APRS:)N0HOME!4800.00N/00900.00EAfremdes Item", at: 20)
        XCTAssertEqual(table.count, 4)
        let station = table.stations["N0HOME"]
        XCTAssertEqual(station?.kind, .station)
        XCTAssertEqual(station?.latitude ?? 0, 47.5, accuracy: 1e-9)
        XCTAssertEqual(station?.comment, "Zuhause")
        XCTAssertEqual(station?.track.count, 1)
        XCTAssertNil(station?.owner)
        XCTAssertEqual(table.stations[";N0HOME"]?.kind, .object)
        XCTAssertEqual(table.stations[";N0HOME"]?.latitude ?? 0, 49 + 3.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(table.stations[")N0HOME"]?.kind, .item)

        _ = ingest(&table, "N0OTHER>APRS:;N0HOME   _092345z4903.50N/07201.75W>", at: 30)
        _ = ingest(&table, "N0OTHER>APRS:)N0HOME_4800.00N/00900.00EA", at: 40)
        XCTAssertNotNil(table.stations["N0HOME"])
        XCTAssertNil(table.stations[";N0HOME"])
        XCTAssertNil(table.stations[")N0HOME"])
        XCTAssertEqual(table.stations["N0HOME"]?.latitude ?? 0, 47.5, accuracy: 1e-9)
    }

    func testOwnTransmissionIsMarkedUntilHeardFromElsewhere() {
        var table = APRSStationTable()
        let own = try! APRSParser.parse("N0CALL-7>APZHMT,WIDE1-1,WIDE2-1:=4730.00N/00915.00El")
        table.ingest(own, receivedAt: t0, isOwn: true)
        XCTAssertEqual(table.stations["N0CALL-7"]?.lastPacketIsOwn, true)
        _ = ingest(&table, "N0CALL-7>APZHMT,WIDE1-1,WIDE2-1,qAR,N0GATE:=4730.00N/00915.00El", at: 5)
        XCTAssertEqual(table.stations["N0CALL-7"]?.lastPacketIsOwn, false)
        XCTAssertEqual(table.stations["N0CALL-7"]?.packetCount, 2)
    }

    func testThirdPartyCountsForInnerStation() {
        var table = APRSStationTable()
        let changed = ingest(&table, "N0GATE>APRS:}N0INNER>APRS,TCPIP,N0GATE*:!4903.50N/07201.75W-")
        XCTAssertEqual(changed, ["N0INNER"])
        XCTAssertNil(table.stations["N0GATE"])
        XCTAssertEqual(table.stations["N0INNER"]?.hasPosition, true)
    }

    func testCategories() {
        var table = APRSStationTable()
        _ = ingest(&table, "N0DIGI>APRS:!4903.50N/07201.75W#Digi")
        _ = ingest(&table, "N0GATE>APRS:!4903.50N/07201.75W&iGate")
        _ = ingest(&table, "N0HOME>APRS:!4903.50N/07201.75W-")
        _ = ingest(&table, "N0WX>APRS:!4903.50N/07201.75W_220/004g005t077")
        _ = ingest(&table, "N0TEXT>APRS:>nur Status")
        XCTAssertEqual(table.stations["N0DIGI"]?.category, .digipeater)
        XCTAssertEqual(table.stations["N0GATE"]?.category, .gateway)
        XCTAssertEqual(table.stations["N0HOME"]?.category, .fixed)
        XCTAssertEqual(table.stations["N0WX"]?.category, .weather)
        XCTAssertEqual(table.stations["N0TEXT"]?.category, .fixed)
    }

    func testExpireUsesGivenClock() {
        var table = APRSStationTable()
        _ = ingest(&table, "N0OLD>APRS:>alt", at: 0)
        _ = ingest(&table, "N0NEW>APRS:>neu", at: 3_000)
        let revision = table.revision
        XCTAssertEqual(table.expire(maxAge: 3_600, now: t0.addingTimeInterval(3_500)), 0)
        XCTAssertEqual(table.revision, revision)
        XCTAssertEqual(table.expire(maxAge: 3_600, now: t0.addingTimeInterval(3_700)), 1)
        XCTAssertNil(table.stations["N0OLD"])
        XCTAssertNotNil(table.stations["N0NEW"])
        XCTAssertGreaterThan(table.revision, revision)
    }

    func testEvictsLongestUnheardWhenFull() {
        var table = APRSStationTable(maxStations: 3)
        for (index, call) in ["N0A", "N0B", "N0C"].enumerated() {
            _ = ingest(&table, "\(call)>APRS:>x", at: Double(index))
        }
        _ = ingest(&table, "N0A>APRS:>wieder da", at: 10)
        _ = ingest(&table, "N0D>APRS:>neu", at: 11)
        XCTAssertEqual(Set(table.stations.keys), ["N0A", "N0C", "N0D"])
        // Objekt plus Absender in einem Paket: beide bleiben, auch wenn die Grenze greift.
        _ = ingest(&table, "N0E>APRS:;LEADER   *092345z4903.50N/07201.75W>", at: 12)
        XCTAssertEqual(table.count, 3)
        XCTAssertNotNil(table.stations["N0E"])
        XCTAssertNotNil(table.stations[";LEADER"])
    }

    /// Der ganze Korpus läuft durch den Speicher; Grenzen halten.
    func testCorpusFillsTableWithinLimits() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/corpus.txt")
        let lines = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).map(Array.init)
        var table = APRSStationTable(maxStations: 100, maxTrackPoints: 5)
        for (index, line) in lines.enumerated() {
            guard let packet = try? APRSParser.parse(line) else { continue }
            table.ingest(packet, receivedAt: t0.addingTimeInterval(Double(index)))
            XCTAssertLessThanOrEqual(table.count, 100)
        }
        XCTAssertEqual(table.count, 100)
        XCTAssertTrue(table.stations.values.allSatisfy { $0.track.count <= 5 })
        XCTAssertGreaterThan(table.stations.values.filter(\.hasPosition).count, 50)
        XCTAssertEqual(table.revision, lines.count)
    }

    // MARK: - Selbst über Funk gehört

    func testRadioReceptionIsRememberedSeparately() throws {
        var table = APRSStationTable()
        let viaNet = try APRSParser.parse("N0CALL-9>APRS,TCPIP*,qAC,T2TEST:=4903.50N/07201.75W>")
        let viaRadio = try APRSParser.parse("N0CALL-9>APRS,WIDE1-1:=4903.50N/07201.75W>")
        table.ingest(viaNet, receivedAt: t0)
        XCTAssertNil(table.stations["N0CALL-9"]?.lastHeardOnRadio)
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastPacketViaRadio, false)

        table.ingest(viaRadio, receivedAt: t0.addingTimeInterval(10), transport: .radio)
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastHeardOnRadio, t0.addingTimeInterval(10))
        XCTAssertEqual(table.stations["N0CALL-9"]?.radioPacketCount, 1)
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastPacketViaRadio, true)

        // Danach wieder übers Internet: der Funk-Zeitpunkt bleibt, das letzte Paket kam aber nicht über Funk.
        table.ingest(viaNet, receivedAt: t0.addingTimeInterval(20))
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastHeardOnRadio, t0.addingTimeInterval(10))
        XCTAssertEqual(table.stations["N0CALL-9"]?.lastPacketViaRadio, false)
        XCTAssertEqual(table.stations["N0CALL-9"]?.packetCount, 3)
    }

    func testOwnTransmissionAndThirdPartyAreNotHeardOnRadio() throws {
        var table = APRSStationTable()
        // Eigene Aussendung über Funk: gesendet, nicht gehört.
        let own = try APRSParser.parse("N0CALL-7>APZHMT,WIDE1-1:=4903.50N/07201.75Wl")
        table.ingest(own, receivedAt: t0, isOwn: true, transport: .radio)
        XCTAssertNil(table.stations["N0CALL-7"]?.lastHeardOnRadio)
        // Third-Party: gesendet hat das iGate, nicht die Station im inneren Paket.
        let third = try APRSParser.parse("N0GATE>APRS:}N0FAR>APRS,TCPIP,N0GATE*:=4903.50N/07201.75W-")
        table.ingest(third, receivedAt: t0, transport: .radio)
        XCTAssertNotNil(table.stations["N0FAR"])
        XCTAssertNil(table.stations["N0FAR"]?.lastHeardOnRadio)
    }

    func testObjectFromRadioPacketCountsAsHeardOnRadio() throws {
        var table = APRSStationTable()
        let object = try APRSParser.parse("N0CALL>APRS:;TREFF    *092345z4903.50N/07201.75W;Fieldday")
        let changed = table.ingest(object, receivedAt: t0, transport: .radio)
        let key = try XCTUnwrap(changed.first { $0 != "N0CALL" })
        XCTAssertEqual(table.stations[key]?.lastHeardOnRadio, t0)
        XCTAssertEqual(table.stations["N0CALL"]?.lastHeardOnRadio, t0)
    }
}
