import XCTest
@testable import APRSKit

final class APRSTransmitGuardTests: XCTestCase {

    func testRegionSuggestions() {
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: 47.38, longitude: 8.54), .iaruRegion1)   // Zürich
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: -33.9, longitude: 18.4), .iaruRegion1)   // Kapstadt
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: 55.75, longitude: 37.6), .iaruRegion1)   // Moskau
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: 62.0, longitude: 129.7), .iaruRegion1)   // Jakutsk
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: 40.7, longitude: -74.0), .northAmerica)  // New York
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: 49.3, longitude: -123.1), .northAmerica) // Vancouver
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: -33.87, longitude: 151.2), .australia)   // Sydney
        XCTAssertEqual(APRSRadioRegion.suggested(latitude: -41.3, longitude: 174.8), .newZealand)   // Wellington
        // Ohne belegte oder eindeutige Zuordnung: kein Vorschlag.
        XCTAssertNil(APRSRadioRegion.suggested(latitude: 35.7, longitude: 139.7))                   // Tokio
        XCTAssertNil(APRSRadioRegion.suggested(latitude: -23.5, longitude: -46.6))                  // São Paulo
        XCTAssertNil(APRSRadioRegion.suggested(latitude: 19.1, longitude: 72.9))                    // Mumbai
        XCTAssertNil(APRSRadioRegion.suggested(latitude: .nan, longitude: 0))
    }

    func testFrequencies() {
        XCTAssertEqual(APRSRadioRegion.iaruRegion1.frequencyHz, 144_800_000)
        XCTAssertEqual(APRSRadioRegion.northAmerica.frequencyHz, 144_390_000)
        XCTAssertEqual(APRSRadioRegion.australia.frequencyHz, 145_175_000)
        XCTAssertEqual(APRSRadioRegion.newZealand.frequencyHz, 144_575_000)
    }

    func testGuardDecisions() {
        let guardian = APRSTransmitGuard(expectedHz: 144_800_000)
        XCTAssertEqual(guardian.check(rigFrequencyHz: 144_800_000), .allowed)
        XCTAssertEqual(guardian.check(rigFrequencyHz: 144_801_000), .allowed)
        XCTAssertEqual(guardian.check(rigFrequencyHz: 144_799_000), .allowed)
        XCTAssertEqual(guardian.check(rigFrequencyHz: 144_801_001),
                       .blockedOffFrequency(rigHz: 144_801_001, expectedHz: 144_800_000))
        XCTAssertEqual(guardian.check(rigFrequencyHz: 14_220_000),
                       .blockedOffFrequency(rigHz: 14_220_000, expectedHz: 144_800_000))
        XCTAssertEqual(guardian.check(rigFrequencyHz: nil), .blockedFrequencyUnknown)
        XCTAssertEqual(guardian.check(rigFrequencyHz: 0), .blockedFrequencyUnknown)
        XCTAssertEqual(APRSTransmitGuard(expectedHz: nil).check(rigFrequencyHz: 144_800_000), .blockedNoTargetFrequency)
    }

    func testDisabledGuardAllowsButFlagsIt() {
        let off = APRSTransmitGuard(isEnabled: false, expectedHz: 144_800_000)
        XCTAssertEqual(off.check(rigFrequencyHz: 14_220_000), .allowedUnprotected)
        XCTAssertEqual(off.check(rigFrequencyHz: nil), .allowedUnprotected)
        XCTAssertEqual(APRSTransmitGuard(expectedHz: 144_800_000, toleranceHz: -5).toleranceHz, 0)
    }
}
