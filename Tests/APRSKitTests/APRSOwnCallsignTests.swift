import XCTest
@testable import APRSKit

final class APRSOwnCallsignTests: XCTestCase {

    func testBaseNormalizes() {
        XCTAssertEqual(APRSOwnCallsign.base(" n0call-7 "), "N0CALL")
        XCTAssertEqual(APRSOwnCallsign.base("N0CALL"), "N0CALL")
        XCTAssertEqual(APRSOwnCallsign.base("  "), "")
    }

    func testChoicesProfileFirstWithoutDuplicates() {
        XCTAssertEqual(
            APRSOwnCallsign.choices(profileCall: "n0call", licensedCalls: ["N1CLUB", " N0CALL ", "", "n1club"]),
            ["N0CALL", "N1CLUB"])
        XCTAssertEqual(APRSOwnCallsign.choices(profileCall: "", licensedCalls: ["N1CLUB"]), ["N1CLUB"])
        XCTAssertEqual(APRSOwnCallsign.choices(profileCall: "N0CALL", licensedCalls: []), ["N0CALL"])
    }

    func testEmptySelectionFollowsProfile() {
        XCTAssertEqual(
            APRSOwnCallsign.effective(selected: "", profileCall: "N0CALL", licensedCalls: ["N0CALL", "N1CLUB"]),
            "N0CALL")
    }

    func testSelectionFromLicenseWins() {
        XCTAssertEqual(
            APRSOwnCallsign.effective(selected: "n1club", profileCall: "N0CALL", licensedCalls: ["N0CALL", "N1CLUB"]),
            "N1CLUB")
    }

    /// Lizenz gewechselt oder entfernt: nie unter einem Call senden, der nicht mehr gedeckt ist.
    func testSelectionOutsideLicenseFallsBackToProfile() {
        XCTAssertEqual(
            APRSOwnCallsign.effective(selected: "N1CLUB", profileCall: "N0CALL", licensedCalls: ["N0CALL"]),
            "N0CALL")
        XCTAssertEqual(
            APRSOwnCallsign.effective(selected: "N1CLUB", profileCall: "N0CALL", licensedCalls: []),
            "N0CALL")
        XCTAssertEqual(APRSOwnCallsign.effective(selected: "N1CLUB", profileCall: "", licensedCalls: []), "")
    }
}
