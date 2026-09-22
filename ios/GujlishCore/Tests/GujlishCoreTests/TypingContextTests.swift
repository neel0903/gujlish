import XCTest
import GujlishCore

final class TypingContextTests: XCTestCase {
    private func parse(_ s: String) -> [String?] {
        let c = TypingContext(before: s)
        return [c.typed, c.prev, c.prev2]
    }

    func testParsing() {
        XCTAssertEqual(parse(""), ["", nil, nil])
        XCTAssertEqual(parse("   "), ["", nil, nil])
        XCTAssertEqual(parse("ke"), ["ke", nil, nil])
        XCTAssertEqual(parse("kem ch"), ["ch", "kem", nil])
        XCTAssertEqual(parse("tame kem ch"), ["ch", "kem", "tame"])
        XCTAssertEqual(parse("tame kem "), ["", "kem", "tame"])
        XCTAssertEqual(parse("are tame kem cho"), ["cho", "kem", "tame"])
        XCTAssertEqual(parse("Kem cho? maj"), ["maj", "cho", "Kem"])
        XCTAssertEqual(parse("kem\ncho\n"), ["", "cho", "kem"])
        XCTAssertEqual(parse("કેમ છો ke"), ["ke", nil, nil])
        XCTAssertEqual(parse("ok 👍 sa"), ["sa", "ok", nil])
        XCTAssertEqual(parse("12"), ["", nil, nil])
    }
}
