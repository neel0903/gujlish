// Which key a set of fingers is typing. Pure logic, no UIKit, so that
// fast and overlapping finger sequences can be replayed in unit tests.
//
// The rules, the same ones the system keyboard follows:
//   - a key is committed when its finger lifts, or as soon as another
//     finger lands (two-thumb typing must keep its letter order)
//   - a finger that skids a little stays on its key; it takes a clear move
//     into a neighbour to switch
//   - a touch the system cancels still types its letter if it was a plain
//     short tap, because a dropped letter is worse than a rare extra one
//   - some keys act when pressed (shift), and delete repeats while held

import CoreGraphics

public final class TouchTracker<Kind: Equatable> {
    public enum Behavior { case onRelease, onPress, repeating }

    public struct Key {
        public let kind: Kind
        public let slot: CGRect
        public let behavior: Behavior
        /// Letters and the like: typed even when the system cancels the touch.
        public let survivesCancel: Bool
        /// Holding the key types something else (q -> 1).
        public let hasAlternate: Bool

        public init(kind: Kind, slot: CGRect, behavior: Behavior = .onRelease, survivesCancel: Bool = false,
                    hasAlternate: Bool = false) {
            self.kind = kind
            self.slot = slot
            self.behavior = behavior
            self.survivesCancel = survivesCancel
            self.hasAlternate = hasAlternate
        }
    }

    public enum Event: Equatable {
        case press(Int)          // show key (index) as pressed
        case release(Int)
        case commit(Int)         // the key acts now
        case startRepeat(Int)
        case stopRepeat
        /// The key was held: type its alternate. `replacesTyped` when the
        /// key already typed its letter on press, which must go first.
        case alternate(Int, replacesTyped: Bool)
    }

    private struct Finger {
        var key: Int
        var done: Bool           // acted already: onPress, repeating, or committed by the next finger
        let began: Double
        var alternated = false
        var serial = 0           // value of `commits` right after this finger's own commit
    }

    private var commits = 0      // every commit so far; tells whether anything was typed since

    public private(set) var keys: [Key] = []
    private var fingers: [AnyHashable: Finger] = [:]
    private var order: [AnyHashable] = []    // fingers in landing order

    // How far past its own slot a finger must go before the neighbour takes over.
    public var slack = CGSize(width: 9, height: 12)
    /// A cancelled touch shorter than this still types.
    public var tapDuration = 0.35

    public init() {}

    /// New layout. Anything still held is committed first, so a layout
    /// change (shift, 123) never eats a letter.
    public func setKeys(_ newKeys: [Key]) -> [Event] {
        let events = flush()
        keys = newKeys
        return events
    }

    public func flush() -> [Event] {
        var events: [Event] = []
        for id in order { events += lift(id, commit: true) }
        return events
    }

    public func began(_ id: AnyHashable, at point: CGPoint, time: Double) -> [Event] {
        var events: [Event] = []
        // A new finger commits whatever the other fingers are holding.
        for other in order where fingers[other]?.done == false {
            guard let f = fingers[other] else { continue }
            events += [.commit(f.key), .release(f.key)]
            commits += 1
            fingers[other]?.done = true
        }
        guard let index = key(at: point) else { return events }
        if fingers[id] != nil { events += lift(id, commit: false) }   // a reused id; never expected
        var finger = Finger(key: index, done: false, began: time)
        events.append(.press(index))
        switch keys[index].behavior {
        case .onRelease:
            break
        case .onPress:
            finger.done = true
            events.append(.commit(index))
            commits += 1
        case .repeating:
            finger.done = true
            events += [.commit(index), .startRepeat(index)]
            commits += 1
        }
        finger.serial = commits
        fingers[id] = finger
        order.append(id)
        return events
    }

    public func moved(_ id: AnyHashable, to point: CGPoint) -> [Event] {
        guard let finger = fingers[id], !finger.done,
              !keys[finger.key].slot.insetBy(dx: -slack.width, dy: -slack.height).contains(point),
              let index = key(at: point), index != finger.key,
              keys[index].behavior == .onRelease else { return [] }
        fingers[id]?.key = index
        return [.release(finger.key), .press(index)]
    }

    public func ended(_ id: AnyHashable, at point: CGPoint) -> [Event] {
        let events = moved(id, to: point)
        return events + lift(id, commit: true)
    }

    public func cancelled(_ id: AnyHashable, time: Double) -> [Event] {
        guard let finger = fingers[id] else { return [] }
        let tap = time - finger.began < tapDuration
        return lift(id, commit: tap && keys[finger.key].survivesCancel)
    }

    /// The key a finger is on, for the caller's long-press timer.
    public func heldKey(_ id: AnyHashable) -> Int? { fingers[id]?.key }

    /// The caller's timer says finger `id` has rested on key `index` long
    /// enough. Nothing happens if the finger has moved on, or if something
    /// else was typed after its letter (replacing would hit the wrong one).
    public func held(_ id: AnyHashable, on index: Int) -> [Event] {
        guard let finger = fingers[id], finger.key == index, keys[index].hasAlternate, !finger.alternated else { return [] }
        switch keys[index].behavior {
        case .onRelease:
            if finger.done { return [] }
            fingers[id]?.done = true
            fingers[id]?.alternated = true
            commits += 1
            return [.alternate(index, replacesTyped: false), .release(index)]
        case .onPress:
            if finger.serial != commits { return [] }
            fingers[id]?.alternated = true
            return [.alternate(index, replacesTyped: true)]
        case .repeating:
            return []
        }
    }

    private func lift(_ id: AnyHashable, commit: Bool) -> [Event] {
        guard let finger = fingers.removeValue(forKey: id) else { return [] }
        order.removeAll { $0 == id }
        var events: [Event] = []
        if keys[finger.key].behavior == .repeating { events.append(.stopRepeat) }
        if !finger.done {
            if commit {
                events.append(.commit(finger.key))
                commits += 1
            }
            events.append(.release(finger.key))
        } else if keys[finger.key].behavior != .onRelease || finger.alternated {
            events.append(.release(finger.key))
        }
        return events
    }

    // The slot under the point, else the nearest one (a finger that lands
    // a hair outside the grid still means the closest key).
    private func key(at point: CGPoint) -> Int? {
        if let hit = keys.firstIndex(where: { $0.slot.contains(point) }) { return hit }
        return keys.indices.min {
            distance(keys[$0].slot, point) < distance(keys[$1].slot, point)
        }
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
