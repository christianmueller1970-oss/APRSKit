import XCTest
@testable import APRSKit

final class APRSSymbolTests: XCTestCase {

    func testPrimaryAndAlternateTable() {
        XCTAssertEqual(APRSSymbol.sprite(table: "/", code: "!"), APRSSymbolSprite(sheet: 0, index: 0))
        XCTAssertEqual(APRSSymbol.sprite(table: "/", code: ">"), APRSSymbolSprite(sheet: 0, index: 29))
        XCTAssertEqual(APRSSymbol.sprite(table: "/", code: "-"), APRSSymbolSprite(sheet: 0, index: 12))
        XCTAssertEqual(APRSSymbol.sprite(table: "\\", code: "_"), APRSSymbolSprite(sheet: 1, index: 62))
        XCTAssertEqual(APRSSymbol.sprite(table: "/", code: "~"), APRSSymbolSprite(sheet: 0, index: 93))
    }

    func testOverlayUsesAlternateTablePlusCharacter() {
        XCTAssertEqual(APRSSymbol.sprite(table: "L", code: "#"),
                       APRSSymbolSprite(sheet: 1, index: 2, overlayIndex: 43))
        XCTAssertEqual(APRSSymbol.sprite(table: "1", code: "#"),
                       APRSSymbolSprite(sheet: 1, index: 2, overlayIndex: 16))
    }

    func testUnknownTablesAndCodes() {
        XCTAssertNil(APRSSymbol.sprite(table: "a", code: ">"))    // Kleinbuchstaben nur in der Kompression
        XCTAssertNil(APRSSymbol.sprite(table: "!", code: ">"))
        XCTAssertNil(APRSSymbol.sprite(table: "/", code: " "))
        XCTAssertNil(APRSSymbol.sprite(table: "/", code: "\u{7F}"))
        XCTAssertNil(APRSSymbol.sprite(table: "/", code: "ä"))
    }

    func testBrandLogosHaveNoImage() {
        XCTAssertNil(APRSSymbol.sprite(table: "/", code: "M"))
        XCTAssertNil(APRSSymbol.sprite(table: "/", code: "Z"))
        XCTAssertNil(APRSSymbol.sprite(table: "\\", code: "K"))
        XCTAssertNil(APRSSymbol.sprite(table: "A", code: "K"))    // Overlay auf derselben Zelle
        // Dieselben Zeichen in der jeweils anderen Tabelle bleiben.
        XCTAssertNotNil(APRSSymbol.sprite(table: "\\", code: "M"))
        XCTAssertNotNil(APRSSymbol.sprite(table: "/", code: "K"))
    }

    /// Jede Zelle bleibt im Blatt (16 × 6 = 96 Zellen).
    func testAllSpritesStayInsideTheSheet() {
        for table in ["/", "\\", "0", "9", "A", "Z"] {
            for code in UInt8(33)...UInt8(126) {
                guard let sprite = APRSSymbol.sprite(table: Character(table),
                                                     code: Character(UnicodeScalar(code))) else { continue }
                XCTAssertTrue((0..<96).contains(sprite.index))
                XCTAssertTrue((0...1).contains(sprite.sheet))
                if let overlay = sprite.overlayIndex { XCTAssertTrue((0..<96).contains(overlay)) }
            }
        }
    }
}
