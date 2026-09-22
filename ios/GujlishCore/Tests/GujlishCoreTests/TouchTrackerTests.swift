// Finger sequences, including the fast and overlapping ones that are
// hard to reproduce by hand.

import XCTest
import GujlishCore

final class TouchTrackerTests: XCTestCase {
    private typealias Tracker = TouchTracker<String>
    private var tracker: Tracker!
    private var typed = ""
    private var pressed: Set<Int> = []
    private var repeating = false

    // One row: a b c d at x = 0, 40, 80, 120 (40 wide, 50 tall), then shift and delete.
    override func setUp() {
        tracker = Tracker()
        typed = ""
        pressed = []
        repeating = false
        var keys = ["a", "b", "c", "d"].enumerated().map {
            Tracker.Key(kind: $1, slot: CGRect(x: CGFloat($0) * 40, y: 0, width: 40, height: 50), survivesCancel: true)
        }
        keys.append(Tracker.Key(kind: "SHIFT", slot: CGRect(x: 160, y: 0, width: 40, height: 50), behavior: .onPress))
        keys.append(Tracker.Key(kind: "DEL", slot: CGRect(x: 200, y: 0, width: 40, height: 50), behavior: .repeating))
        apply(tracker.setKeys(keys))
    }

    private func apply(_ events: [Tracker.Event]) {
        for e in events {
            switch e {
            case .press(let i): pressed.insert(i)
            case .release(let i): pressed.remove(i)
            case .commit(let i): typed += tracker.keys[i].kind == "DEL" ? "<" : tracker.keys[i].kind
            case .startRepeat: repeating = true
            case .stopRepeat: repeating = false
            case .alternate(let i, let replaces):
                if replaces { typed.removeLast() }
                typed += tracker.keys[i].kind.uppercased() + "!"
            }
        }
    }

    private func p(_ x: CGFloat, _ y: CGFloat = 25) -> CGPoint { CGPoint(x: x, y: y) }

    func testTap() {
        apply(tracker.began(1, at: p(10), time: 0))
        XCTAssertEqual(pressed, [0])
        XCTAssertEqual(typed, "", "a key types when the finger lifts")
        apply(tracker.ended(1, at: p(10)))
        XCTAssertEqual(typed, "a")
        XCTAssertEqual(pressed, [])
    }

    func testRolloverKeepsLetterOrder() {
        apply(tracker.began(1, at: p(10), time: 0))       // a down
        apply(tracker.began(2, at: p(50), time: 0.02))    // b down: a is typed now
        XCTAssertEqual(typed, "a")
        apply(tracker.ended(2, at: p(50)))                // b lifts first
        apply(tracker.ended(1, at: p(10)))                // a lifts last: must not type again
        XCTAssertEqual(typed, "ab")
        XCTAssertEqual(pressed, [])
    }

    func testThreeFingersOverlapping() {
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.began(2, at: p(50), time: 0.01))
        apply(tracker.began(3, at: p(90), time: 0.02))
        apply(tracker.ended(1, at: p(10)))
        apply(tracker.ended(3, at: p(90)))
        apply(tracker.ended(2, at: p(50)))
        XCTAssertEqual(typed, "abc")
        XCTAssertEqual(pressed, [])
    }

    func testTwoFingersLandingInOneEvent() {
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.began(2, at: p(50), time: 0))
        apply(tracker.ended(1, at: p(10)))
        apply(tracker.ended(2, at: p(50)))
        XCTAssertEqual(typed, "ab")
    }

    func testVeryFastAlternation() {
        var expected = ""
        var t = 0.0
        for i in 0..<200 {
            let key = i % 4
            apply(tracker.began(i, at: p(CGFloat(key) * 40 + 20), time: t))
            if i > 0 { apply(tracker.ended(i - 1, at: p(CGFloat((i - 1) % 4) * 40 + 20))) }
            expected += ["a", "b", "c", "d"][key]
            t += 0.015
        }
        apply(tracker.ended(199, at: p(3 * 40 + 20)))
        XCTAssertEqual(typed, expected)
        XCTAssertEqual(pressed, [])
    }

    func testSkidStaysOnKey() {
        apply(tracker.began(1, at: p(36), time: 0))       // a, near its right edge
        apply(tracker.moved(1, to: p(45)))                // 5 pt into b: still a
        XCTAssertEqual(pressed, [0])
        apply(tracker.ended(1, at: p(47)))
        XCTAssertEqual(typed, "a")
    }

    func testClearSlideSwitchesKey() {
        apply(tracker.began(1, at: p(20), time: 0))
        apply(tracker.moved(1, to: p(62)))
        XCTAssertEqual(pressed, [1])
        apply(tracker.ended(1, at: p(62)))
        XCTAssertEqual(typed, "b")
    }

    func testSlideNeverLandsOnShiftOrDelete() {
        apply(tracker.began(1, at: p(140), time: 0))      // d
        apply(tracker.moved(1, to: p(185)))               // well into shift
        apply(tracker.ended(1, at: p(185)))
        XCTAssertEqual(typed, "d")
    }

    func testCancelledTapStillTypes() {
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.cancelled(1, time: 0.1))
        XCTAssertEqual(typed, "a")
        XCTAssertEqual(pressed, [])
    }

    func testCancelledLongPressDoesNot() {
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.cancelled(1, time: 1.0))
        XCTAssertEqual(typed, "")
        XCTAssertEqual(pressed, [])
    }

    func testShiftActsOnPress() {
        apply(tracker.began(1, at: p(170), time: 0))
        XCTAssertEqual(typed, "SHIFT")
        apply(tracker.began(2, at: p(10), time: 0.05))    // shift still held, then a
        apply(tracker.ended(2, at: p(10)))
        apply(tracker.ended(1, at: p(170)))
        XCTAssertEqual(typed, "SHIFTa")
        XCTAssertEqual(pressed, [])
    }

    func testDeleteRepeatsWhileHeld() {
        apply(tracker.began(1, at: p(210), time: 0))
        XCTAssertEqual(typed, "<")
        XCTAssertTrue(repeating)
        apply(tracker.began(2, at: p(10), time: 0.2))     // another finger must not stop or retype it
        XCTAssertEqual(typed, "<")
        XCTAssertTrue(repeating)
        apply(tracker.ended(1, at: p(210)))
        XCTAssertFalse(repeating)
        apply(tracker.ended(2, at: p(10)))
        XCTAssertEqual(typed, "<a")
    }

    func testLayoutChangeCommitsHeldKey() {
        apply(tracker.began(1, at: p(50), time: 0))
        apply(tracker.setKeys(tracker.keys))              // e.g. shift dropped after a capital
        XCTAssertEqual(typed, "b")
        apply(tracker.ended(1, at: p(50)))                // the old finger lifts later: nothing more
        XCTAssertEqual(typed, "b")
        XCTAssertEqual(pressed, [])
    }

    func testTouchJustOutsideTheGrid() {
        apply(tracker.began(1, at: p(10, 53), time: 0))
        apply(tracker.ended(1, at: p(10, 53)))
        XCTAssertEqual(typed, "a")
    }

    func testStrayEventsAreHarmless() {
        apply(tracker.ended(9, at: p(10)))
        apply(tracker.moved(9, to: p(10)))
        apply(tracker.cancelled(9, time: 0))
        XCTAssertEqual(typed, "")
    }

    // Fast keys: letters act when the finger lands.
    func testLettersOnPress() {
        let keys = ["a", "b"].enumerated().map {
            Tracker.Key(kind: $1, slot: CGRect(x: CGFloat($0) * 40, y: 0, width: 40, height: 50), behavior: .onPress)
        } + [Tracker.Key(kind: " ", slot: CGRect(x: 80, y: 0, width: 40, height: 50))]
        apply(tracker.setKeys(keys))
        apply(tracker.began(1, at: p(10), time: 0))
        XCTAssertEqual(typed, "a")
        XCTAssertEqual(pressed, [0])
        apply(tracker.began(2, at: p(100), time: 0.02))   // space (on release) while a is still down
        apply(tracker.began(3, at: p(50), time: 0.04))    // b lands before space lifts: space first
        XCTAssertEqual(typed, "a b")
        apply(tracker.ended(1, at: p(10)))
        apply(tracker.ended(3, at: p(50)))
        apply(tracker.ended(2, at: p(100)))
        XCTAssertEqual(typed, "a b")
        XCTAssertEqual(pressed, [])
    }

    func testTouchAboveTheGridMeansTheTopRow() {
        apply(tracker.began(1, at: p(50, -9), time: 0))
        apply(tracker.ended(1, at: p(50, -9)))
        XCTAssertEqual(typed, "b")
    }

    // Long press. The alternate of "a" is written "A!" here.
    private func useAlternateKeys(_ behavior: Tracker.Behavior) {
        let keys = ["a", "b"].enumerated().map {
            Tracker.Key(kind: $1, slot: CGRect(x: CGFloat($0) * 40, y: 0, width: 40, height: 50),
                        behavior: behavior, survivesCancel: true, hasAlternate: $1 == "a")
        }
        apply(tracker.setKeys(keys))
    }

    func testLongPressTypesTheAlternate() {
        useAlternateKeys(.onRelease)
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.held(1, on: 0))
        XCTAssertEqual(typed, "A!")
        apply(tracker.ended(1, at: p(10)))
        XCTAssertEqual(typed, "A!", "lifting must not type the letter as well")
        XCTAssertEqual(pressed, [])
    }

    func testLongPressWithFastKeysReplacesTheLetter() {
        useAlternateKeys(.onPress)
        apply(tracker.began(1, at: p(10), time: 0))
        XCTAssertEqual(typed, "a")
        apply(tracker.held(1, on: 0))
        XCTAssertEqual(typed, "A!")
        apply(tracker.held(1, on: 0))
        XCTAssertEqual(typed, "A!", "only once")
        apply(tracker.ended(1, at: p(10)))
        XCTAssertEqual(typed, "A!")
        XCTAssertEqual(pressed, [])
    }

    func testLongPressNeverReplacesAnotherFingersLetter() {
        useAlternateKeys(.onPress)
        apply(tracker.began(1, at: p(10), time: 0))       // a, held
        apply(tracker.began(2, at: p(50), time: 0.1))     // b typed meanwhile
        apply(tracker.held(1, on: 0))
        XCTAssertEqual(typed, "ab")
        apply(tracker.ended(2, at: p(50)))
        apply(tracker.ended(1, at: p(10)))
        XCTAssertEqual(typed, "ab")
    }

    func testLongPressIgnoredWhenTheFingerMovedOrLifted() {
        useAlternateKeys(.onRelease)
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.moved(1, to: p(65)))                // now on b, which has no alternate
        apply(tracker.held(1, on: 0))
        apply(tracker.ended(1, at: p(65)))
        XCTAssertEqual(typed, "b")
        apply(tracker.held(1, on: 0))                     // a timer firing after the lift
        XCTAssertEqual(typed, "b")
    }

    func testRolloverBeatsLongPress() {
        useAlternateKeys(.onRelease)
        apply(tracker.began(1, at: p(10), time: 0))
        apply(tracker.began(2, at: p(50), time: 0.1))     // commits a
        apply(tracker.held(1, on: 0))
        XCTAssertEqual(typed, "a")
    }
}
