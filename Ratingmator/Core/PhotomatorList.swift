import Foundation

/// The ratings, flags and sidebar folders in one of Photomator's lists (SPEC 3.1).
nonisolated struct PhotomatorList: Equatable, Sendable {
    enum ReadError: Error, Equatable {
        case notAPropertyList
        case unsupportedVersion
        case unexpectedStructure(String)
    }

    private static let topLevelKeys: Set<String> = [
        "version", "directories", "looseImages", "flagsAndRatings",
        "directoryOrder", "displaysFolderContentsRecursively",
    ]

    let ratings: [String: Int]
    let flags: [String: Flag]
    let sidebarFolders: [String]
    private let normalizedRatings: [String: Int]
    private let normalizedFlags: [String: Flag]

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else {
            throw ReadError.notAPropertyList
        }
        guard root["version"] as? Int == 3 else {
            throw ReadError.unsupportedVersion
        }
        guard Set(root.keys) == Self.topLevelKeys else {
            throw ReadError.unexpectedStructure("top-level keys")
        }
        guard let flagsAndRatings = root["flagsAndRatings"] as? [String: Any],
              let rated = flagsAndRatings["ratedAssets"] as? [String: Int],
              let flagged = flagsAndRatings["flaggedAssets"] as? [String: Int] else {
            throw ReadError.unexpectedStructure("flagsAndRatings")
        }
        guard rated.values.allSatisfy((1...5).contains) else {
            throw ReadError.unexpectedStructure("ratedAssets")
        }
        let flags = flagged.compactMapValues { $0 == 0 ? nil : Flag(rawValue: $0) }
        guard flags.count == flagged.count else {
            throw ReadError.unexpectedStructure("flaggedAssets")
        }
        guard let directories = root["directories"] as? [[String: Any]] else {
            throw ReadError.unexpectedStructure("directories")
        }
        let folders = directories.compactMap { directory -> String? in
            guard let url = directory["url"] as? [String: Any],
                  let relative = url["relative"] as? String else { return nil }
            return URL(string: relative)?.path
        }
        guard folders.count == directories.count else {
            throw ReadError.unexpectedStructure("directories")
        }

        self.init(ratings: rated, flags: flags, sidebarFolders: folders)
    }

    init(ratings: [String: Int], flags: [String: Flag], sidebarFolders: [String]) {
        self.ratings = ratings
        self.flags = flags
        self.sidebarFolders = sidebarFolders
        self.normalizedRatings = Self.normalized(ratings)
        self.normalizedFlags = Self.normalized(flags)
    }

    /// The list's value for a photo, with the key compared Unicode-normalised (SPEC 8.7).
    /// A photo without an entry has no value: the list takes no part for it (SPEC 5.1).
    func value(forKey key: String) -> PhotoValue {
        let normalizedKey = key.precomposedStringWithCanonicalMapping
        return PhotoValue(stars: normalizedRatings[normalizedKey], flag: normalizedFlags[normalizedKey])
    }

    private static func normalized<Value>(_ entries: [String: Value]) -> [String: Value] {
        Dictionary(
            entries.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
