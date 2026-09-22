// The personal dictionary on disk: one JSON file in the keyboard's own
// container, in the web app's export format. Written atomically, so a
// keyboard killed mid-write never leaves half a file.

import Foundation

public struct PersonalStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Nil when nothing has been saved yet or the file cannot be read.
    public func load() -> PersonalData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersonalData.self, from: data)
    }

    public func save(_ personal: PersonalData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(personal).write(to: url, options: .atomic)
    }
}
