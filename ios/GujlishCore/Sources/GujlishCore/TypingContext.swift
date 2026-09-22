// What the engine needs from the text before the cursor: the word being
// typed and the two words before it, the way the web app's split() does.
// The keyboard gets that text from the host app, so this must cope with
// anything: empty, only spaces, punctuation, other scripts.

public struct TypingContext: Equatable {
    public let typed: String
    public let prev: String?
    public let prev2: String?

    public init(typed: String, prev: String?, prev2: String?) {
        self.typed = typed
        self.prev = prev
        self.prev2 = prev2
    }

    public init(before: String) {
        func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        let typed = String(before.reversed().prefix(while: isLetter).reversed())
        let words = before.dropLast(typed.count)
            .split(whereSeparator: { !isLetter($0) }).suffix(2).map(String.init)
        self.typed = typed
        self.prev = words.last
        self.prev2 = words.count > 1 ? words[0] : nil
    }
}
