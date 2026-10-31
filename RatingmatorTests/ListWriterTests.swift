import Foundation
import Testing
@testable import Ratingmator

private let bookmark = Data((0..<255).map { UInt8($0) })
private let importDate = Date(timeIntervalSince1970: 1_790_000_000)

private func plist(
    ratings: [String: Int] = [:],
    flags: [String: Int] = [:],
    folders: [String] = ["file:///photos/"]
) -> [String: Any] {
    [
        "version": 3,
        "directories": folders.map { folder -> [String: Any] in
            [
                "bookmarkData": bookmark,
                "id": [1, ["62BCF721-E2FD-430F-9C85-F6BFE89CE6AF"]] as [Any],
                "importDate": importDate,
                "isRemovableVolume": false,
                "url": ["relative": folder],
                "version": 1,
            ]
        },
        "looseImages": [Any](),
        "flagsAndRatings": ["ratedAssets": ratings, "flaggedAssets": flags],
        "directoryOrder": ["62BCF721-E2FD-430F-9C85-F6BFE89CE6AF"],
        "displaysFolderContentsRecursively": true,
    ]
}

private func encode(_ root: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}

private func decode(_ url: URL) throws -> [String: Any] {
    try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

private func jpg(_ path: String, _ value: PhotoValue, skipped: Bool = false) -> PhotoDecision {
    PhotoDecision(
        photo: Photo(kind: .embedded, imageURL: URL(fileURLWithPath: path), rawURL: nil, sidecarURL: nil),
        sources: PhotoSources(), conflict: nil, value: value,
        changesImage: false, changesSidecar: false, isSkipped: skipped
    )
}

private func raw(_ path: String, _ value: PhotoValue) -> PhotoDecision {
    PhotoDecision(
        photo: Photo(kind: .rawOnly, imageURL: nil, rawURL: URL(fileURLWithPath: path), sidecarURL: nil),
        sources: PhotoSources(), conflict: nil, value: value,
        changesImage: false, changesSidecar: false, isSkipped: false
    )
}

private func pair(_ jpgPath: String, _ rawPath: String, _ value: PhotoValue) -> PhotoDecision {
    PhotoDecision(
        photo: Photo(kind: .pair, imageURL: URL(fileURLWithPath: jpgPath), rawURL: URL(fileURLWithPath: rawPath), sidecarURL: nil),
        sources: PhotoSources(), conflict: nil, value: value,
        changesImage: false, changesSidecar: false, isSkipped: false
    )
}

private func list(ratings: [String: Int] = [:], flags: [String: Flag] = [:]) -> PhotomatorList {
    PhotomatorList(ratings: ratings, flags: flags, sidebarFolders: ["/photos"])
}

struct ListPlanTests {
    @Test func addsChangesAndRemoves() {
        let plan = ListWriter.plan([
            jpg("/photos/new.JPG", PhotoValue(stars: 3, flag: .pick)),
            jpg("/photos/changed.JPG", PhotoValue(stars: 5, flag: .reject)),
            jpg("/photos/removed.JPG", PhotoValue(stars: 0, flag: Flag.none)),
            jpg("/photos/same.JPG", PhotoValue(stars: 2, flag: .pick)),
        ], list: list(
            ratings: ["/photos/changed.JPG": 1, "/photos/removed.JPG": 4, "/photos/same.JPG": 2],
            flags: ["/photos/changed.JPG": .pick, "/photos/removed.JPG": .reject, "/photos/same.JPG": .pick]
        ))

        #expect(plan.ratings == ["/photos/new.JPG": 3, "/photos/changed.JPG": 5, "/photos/same.JPG": 2])
        #expect(plan.flags == ["/photos/new.JPG": 1, "/photos/changed.JPG": -1, "/photos/same.JPG": 1])

        var expected = ListChanges()
        expected.ratingsAdded = 1
        expected.ratingsChanged = 1
        expected.ratingsRemoved = 1
        expected.flagsAdded = 1
        expected.flagsChanged = 1
        expected.flagsRemoved = 1
        #expect(plan.changes == expected)
    }

    @Test func stars0AndNoFlagForAPhotoWithoutEntriesAddNothing() {
        let plan = ListWriter.plan([jpg("/photos/a.JPG", PhotoValue(stars: 0, flag: Flag.none))], list: list())
        #expect(plan.ratings.isEmpty)
        #expect(plan.flags.isEmpty)
        #expect(plan.changes.isEmpty)
    }

    @Test func keysFollowPhotomatorsRules() {
        let plan = ListWriter.plan([
            pair("/photos/p.JPG", "/photos/p.RAF", PhotoValue(stars: 1, flag: nil)),
            raw("/photos/r.RAF", PhotoValue(stars: 2, flag: nil)),
            raw("/photos/d.dng", PhotoValue(stars: 3, flag: nil)),
        ], list: list())
        #expect(plan.ratings == ["/photos/p.JPG": 1, "/photos/r.RAF": 2, "/photos/d.dng": 3])
    }

    @Test func onlyPhotosInsideASidebarFolderTakePart() {
        let plan = ListWriter.plan([
            jpg("/elsewhere/a.JPG", PhotoValue(stars: 3, flag: .pick)),
            jpg("/photos2/a.JPG", PhotoValue(stars: 3, flag: .pick)),
            jpg("/photos/deep/down/a.JPG", PhotoValue(stars: 3, flag: nil)),
        ], list: list())
        #expect(plan.ratings == ["/photos/deep/down/a.JPG": 3])
        #expect(plan.flags.isEmpty)
    }

    @Test func entriesForPhotosNotInTheDecisionsStay() {
        let plan = ListWriter.plan(
            [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
            list: list(ratings: ["/photos/unscanned.JPG": 5, "/offline/b.JPG": 2], flags: ["/offline/b.JPG": .reject])
        )
        #expect(plan.ratings == ["/photos/a.JPG": 3, "/photos/unscanned.JPG": 5, "/offline/b.JPG": 2])
        #expect(plan.flags == ["/offline/b.JPG": -1])
    }

    @Test func aFieldWithoutAFinalValueStays() {
        let plan = ListWriter.plan(
            [jpg("/photos/a.JPG", .empty)],
            list: list(ratings: ["/photos/a.JPG": 4], flags: ["/photos/a.JPG": .pick])
        )
        #expect(plan.ratings == ["/photos/a.JPG": 4])
        #expect(plan.flags == ["/photos/a.JPG": 1])
        #expect(plan.changes.isEmpty)
    }

    /// For an ignored conflict, nothing is written to the list: what's there stays.
    @Test func anIgnoredPhotoStays() {
        var ignored = jpg("/photos/a.JPG", PhotoValue(stars: 0, flag: Flag.none))
        ignored.isIgnored = true
        let plan = ListWriter.plan([ignored], list: list(ratings: ["/photos/a.JPG": 4], flags: ["/photos/a.JPG": .pick]))
        #expect(plan.ratings == ["/photos/a.JPG": 4])
        #expect(plan.flags == ["/photos/a.JPG": 1])
        #expect(plan.changes.isEmpty)
    }

    @Test func aSkippedPhotoStays() {
        let plan = ListWriter.plan(
            [jpg("/photos/a.JPG", PhotoValue(stars: 0, flag: nil), skipped: true)],
            list: list(ratings: ["/photos/a.JPG": 4])
        )
        #expect(plan.ratings == ["/photos/a.JPG": 4])
    }

    @Test func anEntryInAnotherAccentSpellingIsReplacedNotDuplicated() throws {
        let decomposed = "/photos/Argentinie\u{0308}/a.JPG"
        let composed = "/photos/Argentini\u{00EB}/a.JPG"
        let plan = ListWriter.plan([jpg(decomposed, PhotoValue(stars: 2, flag: nil))], list: list(ratings: [composed: 2]))

        #expect(plan.ratings.count == 1)
        let key = try #require(plan.ratings.keys.first)
        #expect(key.unicodeScalars.elementsEqual(decomposed.unicodeScalars))
        #expect(plan.changes.ratingsChanged == 1)
    }

    @Test func aSidebarFolderInAnotherAccentSpellingMatches() {
        let list = PhotomatorList(ratings: [:], flags: [:], sidebarFolders: ["/photos/Argentini\u{00EB}"])
        let plan = ListWriter.plan([jpg("/photos/Argentinie\u{0308}/a.JPG", PhotoValue(stars: 2, flag: nil))], list: list)
        #expect(plan.changes.ratingsAdded == 1)
    }
}

struct ListWriterTests {
    private func setup(_ root: [String: Any] = plist()) throws -> (TemporaryFolder, URL, URL) {
        let folder = try TemporaryFolder()
        let file = try folder.write(encode(root), to: "FilesLibrary.plist")
        return (folder, file, folder.url.appendingPathComponent("backups"))
    }

    private let notRunning: () -> Bool = { false }

    @Test func writesTheListAsABinaryPlistAndKeepsABackup() throws {
        let (folder, file, backups) = try setup(plist(ratings: ["/photos/old.JPG": 1]))
        defer { folder.remove() }
        let before = try Data(contentsOf: file)

        let result = try ListWriter.apply(
            [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: .pick))],
            to: file, backupFolder: backups, photomatorIsRunning: notRunning
        )

        #expect(result.changes.ratingsAdded == 1)
        #expect(result.changes.flagsAdded == 1)

        let written = try PhotomatorList(contentsOf: file)
        #expect(written.ratings == ["/photos/old.JPG": 1, "/photos/a.JPG": 3])
        #expect(written.flags == ["/photos/a.JPG": .pick])

        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: &format)
        #expect(format == .binary)

        let backup = try #require(result.backup)
        #expect(try Data(contentsOf: backup) == before)
    }

    @Test func everyOtherKeyIsIdentical() throws {
        let original = plist()
        let (folder, file, backups) = try setup(original)
        defer { folder.remove() }

        try ListWriter.apply(
            [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
            to: file, backupFolder: backups, photomatorIsRunning: notRunning
        )

        var written = try decode(file)
        var expected = try #require(PropertyListSerialization.propertyList(from: encode(original), format: nil) as? [String: Any])
        written["flagsAndRatings"] = nil
        expected["flagsAndRatings"] = nil
        #expect(ListWriter.isIdentical(written, expected))

        let directories = try #require(written["directories"] as? [[String: Any]])
        #expect(directories[0]["bookmarkData"] as? Data == bookmark)
        #expect(written["displaysFolderContentsRecursively"] as? Bool == true)
    }

    @Test func nothingToChangeMeansNoWriteAndNoBackup() throws {
        let (folder, file, backups) = try setup(plist(ratings: ["/photos/a.JPG": 3]))
        defer { folder.remove() }
        let before = try Data(contentsOf: file)
        let result = try ListWriter.apply(
            [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: Flag.none))],
            to: file, backupFolder: backups, photomatorIsRunning: notRunning
        )
        #expect(result.backup == nil)
        #expect(try Data(contentsOf: file) == before)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func refusesWhilePhotomatorIsRunning() throws {
        let (folder, file, backups) = try setup()
        defer { folder.remove() }
        let before = try Data(contentsOf: file)
        #expect(throws: ListWriter.WriteError.photomatorIsRunning) {
            try ListWriter.apply(
                [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
                to: file, backupFolder: backups, photomatorIsRunning: { true }
            )
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func refusesAnotherVersionOrAnUnknownKeyAndChangesNothing() throws {
        var other = plist()
        other["version"] = 4
        var unknown = plist()
        unknown["somethingNew"] = 1

        for root in [other, unknown] {
            let (folder, file, backups) = try setup(root)
            defer { folder.remove() }
            let before = try Data(contentsOf: file)
            #expect(throws: PhotomatorList.ReadError.self) {
                try ListWriter.apply(
                    [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
                    to: file, backupFolder: backups, photomatorIsRunning: notRunning
                )
            }
            #expect(try Data(contentsOf: file) == before)
            #expect(!FileManager.default.fileExists(atPath: backups.path))
        }
    }

    @Test func ifTheBackupFailsTheListIsNotWritten() throws {
        let (folder, file, _) = try setup()
        defer { folder.remove() }
        let notAFolder = try folder.write(Data(), to: "notAFolder")
        let before = try Data(contentsOf: file)
        #expect(throws: ListWriter.WriteError.backupFailed) {
            try ListWriter.apply(
                [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
                to: file, backupFolder: notAFolder, photomatorIsRunning: notRunning
            )
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func keepsTheFilesAttributesAndLeavesNoTemporaryFile() throws {
        let (folder, file, backups) = try setup()
        defer { folder.remove() }
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .posixPermissions: 0o700], ofItemAtPath: file.path)

        try ListWriter.apply(
            [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
            to: file, backupFolder: backups, photomatorIsRunning: notRunning
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.creationDate] as? Date == created)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names.sorted() == ["FilesLibrary.plist", "backups"])
    }

    // MARK: Failures forced after the write: each must bring the old list back.

    private static func damage(_ change: @escaping (inout [String: Any]) -> Void) -> (URL) throws -> Void {
        { url in
            var root = try #require(
                PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            )
            change(&root)
            try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        }
    }

    private func expectRestored(after damage: @escaping (URL) throws -> Void) throws {
        let (folder, file, backups) = try setup(plist(ratings: ["/photos/old.JPG": 1]))
        defer { folder.remove() }
        let before = try Data(contentsOf: file)

        #expect(throws: ListWriter.WriteError.verificationFailed) {
            try ListWriter.apply(
                [jpg("/photos/a.JPG", PhotoValue(stars: 3, flag: nil))],
                to: file, backupFolder: backups, photomatorIsRunning: notRunning, afterWrite: damage
            )
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
    }

    @Test func aDamagedFileIsRestored() throws {
        try expectRestored { try Data("not a list".utf8).write(to: $0) }
    }

    @Test func aChangedBookmarkIsRestored() throws {
        try expectRestored(after: Self.damage { root in
            var directories = root["directories"] as! [[String: Any]]
            directories[0]["bookmarkData"] = Data([1, 2, 3])
            root["directories"] = directories
        })
    }

    @Test func aDifferentRatingCountIsRestored() throws {
        try expectRestored(after: Self.damage { root in
            root["flagsAndRatings"] = ["ratedAssets": ["/photos/a.JPG": 3], "flaggedAssets": [String: Int]()]
        })
    }

    @Test func aChangedTypeIsRestored() throws {
        try expectRestored(after: Self.damage { root in
            root["displaysFolderContentsRecursively"] = 1
        })
    }

    @Test func aMissingKeyIsRestored() throws {
        try expectRestored(after: Self.damage { root in
            root["looseImages"] = nil
        })
    }

    @Test func anXMLListIsRestored() throws {
        try expectRestored { url in
            let root = try #require(
                PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            )
            try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: url)
        }
    }
}
