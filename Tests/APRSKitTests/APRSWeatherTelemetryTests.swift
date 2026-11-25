import XCTest
@testable import APRSKit

final class APRSWeatherTelemetryTests: XCTestCase {

    private func content(_ payload: String) throws -> APRSContent {
        try APRSParser.parse("N0CALL>APRS:" + payload).content
    }

    private var specWeather: APRSWeather {
        var w = APRSWeather()
        w.windDirectionDegrees = 220
        w.windSpeedMph = 4
        w.gustMph = 5
        w.temperatureFahrenheit = 77
        w.rainLastHour = 0
        w.rainLast24Hours = 0
        w.rainSinceMidnight = 0
        w.humidityPercent = 50
        w.pressureTenthsMillibar = 9900
        return w
    }

    /// Beispiel der Spezifikation (Kapitel 12).
    func testPositionlessWeather() throws {
        XCTAssertEqual(try content("_10090556c220s004g005t077r000p000P000h50b09900wRSW"),
                       .weather(APRSWeatherReport(
                        timestamp: .monthDayHourMinute(month: 10, day: 9, hour: 5, minute: 56),
                        weather: specWeather, comment: "wRSW")))
    }

    func testWeatherInPosition() throws {
        guard case .position(let p) = try content("!4903.50N/07201.75W_220/004g005t077r000p000P000h50b09900wRSW") else {
            return XCTFail("Keine Position")
        }
        XCTAssertEqual(p.weather, specWeather)
        XCTAssertEqual(p.comment, "wRSW")
        XCTAssertNil(p.course)
        XCTAssertEqual(p.latitude, 49 + 3.5 / 60, accuracy: 1e-9)
    }

    /// Spezifikation: komprimierter Wetterbericht, Wind in den cs-Bytes
    /// (`7P` = 88°, 36,2 kn ≈ 42 mph).
    func testCompressedWeatherTakesWindFromCsBytes() throws {
        guard case .position(let p) = try content("@092345z/5L!!<*e7_7P[g005t077r000p000P000h50b09900wRSW") else {
            return XCTFail("Keine Position")
        }
        var expected = specWeather
        expected.windDirectionDegrees = 88
        expected.windSpeedMph = 42
        XCTAssertEqual(p.weather, expected)
        XCTAssertNil(p.course)
        XCTAssertNil(p.speedKnots)
        XCTAssertEqual(p.latitude, 49.5, accuracy: 1e-4)
        XCTAssertEqual(p.comment, "wRSW")
    }

    /// Spezifikation: Regenmesser ohne Windsensor.
    func testRainGaugeWithPlaceholders() throws {
        var expected = APRSWeather()
        expected.rainSinceMidnight = 12
        XCTAssertEqual(try content("_10090556c...s...g...t...P012Jim"),
                       .weather(APRSWeatherReport(
                        timestamp: .monthDayHourMinute(month: 10, day: 9, hour: 5, minute: 56),
                        weather: expected, comment: "Jim")))
    }

    func testLuminositySnowAndRainCounterDoNotCutOffLaterFields() throws {
        guard case .position(let p) = try content("!4903.50N/07201.75W_220/004g005t077L123s1.5#042h50b09900") else {
            return XCTFail("Keine Position")
        }
        XCTAssertEqual(p.weather?.luminosity, 123)
        XCTAssertEqual(p.weather?.snowLast24Hours, 1.5)
        XCTAssertEqual(p.weather?.humidityPercent, 50)
        XCTAssertEqual(p.weather?.pressureTenthsMillibar, 9900)
        XCTAssertEqual(p.weather?.windSpeedMph, 4)
        XCTAssertEqual(p.comment, "")
        guard case .weather(let bright) = try content("_10090556c220s004g005t077l234") else {
            return XCTFail("Kein Wetter")
        }
        XCTAssertEqual(bright.weather.luminosity, 1234)
    }

    func testMissingValuesNegativeTemperatureAndFullHumidity() throws {
        guard case .position(let p) = try content("@092345z4903.50N/07201.75W_.../...g...t-07h00b10132") else {
            return XCTFail("Keine Position")
        }
        var expected = APRSWeather()
        expected.temperatureFahrenheit = -7
        expected.humidityPercent = 100
        expected.pressureTenthsMillibar = 10132
        XCTAssertEqual(p.weather, expected)
        XCTAssertEqual(p.comment, "")
    }

    func testWeatherSymbolWithoutWeatherData() throws {
        guard case .position(let p) = try content("!4903.50N/07201.75W_Wetterstation im Bau") else {
            return XCTFail("Keine Position")
        }
        XCTAssertNil(p.weather)
        XCTAssertEqual(p.comment, "Wetterstation im Bau")
    }

    func testInvalidPositionlessWeatherStaysUnparsed() throws {
        for payload in ["_1009055", "_10090556", "_10090556Text", "_ABCDEFGHc220", "_"] {
            XCTAssertEqual(try content(payload), .unparsed, payload)
        }
    }

    // MARK: - Telemetrie

    /// Beispiel der Spezifikation (Kapitel 13).
    func testTelemetry() throws {
        XCTAssertEqual(try content("T#005,199,000,255,073,123,01101001"),
                       .telemetry(APRSTelemetry(
                        sequence: "005", analog: [199, 0, 255, 73, 123],
                        digital: [false, true, true, false, true, false, false, true], comment: "")))
    }

    /// Weitere Beispiele der Spezifikation: MIC ohne Komma, Dezimal- und negative Werte.
    func testTelemetrySpecVariants() throws {
        XCTAssertEqual(try content("T#MIC199,000,255,073,123,01101001"),
                       .telemetry(APRSTelemetry(
                        sequence: "MIC", analog: [199, 0, 255, 73, 123],
                        digital: [false, true, true, false, true, false, false, true], comment: "")))
        XCTAssertEqual(try content("T#151,45.7,2.3,190.0,91.0,-7.3,00001100"),
                       .telemetry(APRSTelemetry(
                        sequence: "151", analog: [45.7, 2.3, 190.0, 91.0, -7.3],
                        digital: [false, false, false, false, true, true, false, false], comment: "")))
    }

    func testTelemetryVariants() throws {
        XCTAssertEqual(try content("T#MIC,12.5,,7,x"),
                       .telemetry(APRSTelemetry(sequence: "MIC", analog: [12.5, nil, 7, nil],
                                                digital: [], comment: "")))
        XCTAssertEqual(try content("T#12,1,2,3,4,5,0101Solar"),
                       .telemetry(APRSTelemetry(sequence: "12", analog: [1, 2, 3, 4, 5],
                                                digital: [false, true, false, true], comment: "Solar")))
    }

    func testInvalidTelemetryStaysUnparsed() throws {
        for payload in ["T#", "T#005", "T#,1,2", "T#005,x,y", "Test ohne Raute", "T#123456,1"] {
            XCTAssertEqual(try content(payload), .unparsed, payload)
        }
    }

    func testTruncatedAndCorruptedLinesNeverCrash() {
        let lines = [
            "N0CALL>APRS:_10090556c220s004g005t077r000p000P000h50b09900wRSW",
            "N0CALL>APRS:@092345z4903.50N/07201.75W_.../...g...t-07h00b10132",
            "N0CALL>APRS:T#005,199,000,255,073,123,01101001"
        ]
        var generator = SystemRandomNumberGenerator()
        for line in lines {
            let bytes = Array(line.utf8)
            for length in 0...bytes.count {
                _ = try? APRSParser.parse(Array(bytes.prefix(length)))
            }
            for index in bytes.indices {
                for _ in 0..<32 {
                    var corrupted = bytes
                    corrupted[index] = UInt8.random(in: 0...255, using: &generator)
                    _ = try? APRSParser.parse(corrupted)
                }
            }
        }
    }
}
