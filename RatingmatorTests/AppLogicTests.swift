import Foundation
import Testing
@testable import Ratingmator

struct RestoreTests {
    private func validList(ratings: [String: Int], flags: [String: Int] = [:], folder: String = "file:///photos/") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "version": 3,
            "directories": [["url": ["relative": folder], "bookmarkData": Data([1, 2, 3])]],
            "looseImages": [Any](),
            "flagsAndRatings": ["ratedAssets": ratings, "flaggedAssets": flags],
            "directoryOrder": [Any](),
            "displaysFolderContentsRecursively": true,
        ] as [String: Any], format: .binary, options: 0)
    }

    @Test func theComparisonCountsChangesSidebarAndMissing() {
        let chosen = PhotomatorList(
            ratings: ["/a/same.JPG": 1, "/a/changed.JPG": 5, "/a/added.JPG": 2, "/gone/lost.JPG": 3],
            flags: ["/a/same.JPG": .pick],
            sidebarFolders: ["/a", "/gone"]
        )
        let current = PhotomatorList(
            ratings: ["/a/same.JPG": 1, "/a/changed.JPG": 2, "/a/removed.JPG": 4],
            flags: ["/a/removed.JPG": .reject],
            sidebarFolders: ["/a", "/b"]
        )
        let comparison = RestoreComparison(chosen: chosen, current: current) { !$0.hasPrefix("/gone") }

        var expected = ListChanges()
        expected.ratingsAdded = 2
        expected.ratingsChanged = 1
        expected.ratingsRemoved = 1
        expected.flagsAdded = 1
        expected.flagsRemoved = 1
        #expect(comparison.changes == expected)
        #expect(comparison.sidebarFoldersAdded == ["/gone"])
        #expect(comparison.sidebarFoldersRemoved == ["/b"])
        #expect(comparison.missingPhotos == 1)
        #expect(comparison.missingFolders == ["/gone"])
        #expect(comparison.photosInList == ["/a/added.JPG", "/a/changed.JPG", "/a/same.JPG"])
    }

    @Test func backupsAreFoundNewestFirstAndOthersLeftOut() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let old = try folder.write(validList(ratings: ["/a.JPG": 1]), to: "FilesLibrary-old.plist")
        let new = try folder.write(validList(ratings: [:]), to: "FilesLibrary-new.plist")
        try folder.write(Data("broken".utf8), to: "FilesLibrary-broken.plist")
        try folder.write(Data(), to: "sidecars-1.zip")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: new.path)

        let found = ListBackup.all(in: folder.url)
        #expect(found.map(\.url.lastPathComponent) == ["FilesLibrary-new.plist", "FilesLibrary-old.plist"])
        #expect(found[1].ratings == 1)
    }

    @Test func restorePutsTheWholeListBackIncludingSidebarAndBacksUpTheCurrentOne() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let chosenData = try validList(ratings: ["/a.JPG": 1], folder: "file:///old/")
        let currentData = try validList(ratings: ["/b.JPG": 2], folder: "file:///new/")
        let chosen = try folder.write(chosenData, to: "chosen.plist")
        let live = try folder.write(currentData, to: "FilesLibrary.plist")

        let backup = try ListWriter.restore(
            chosen, to: live, backupFolder: folder.url.appendingPathComponent("backups"), photomatorIsRunning: { false }
        )
        #expect(try Data(contentsOf: live) == chosenData)
        #expect(try Data(contentsOf: backup) == currentData)
    }

    @Test func restoreRefusesWhilePhotomatorIsRunningOrABrokenList() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let currentData = try validList(ratings: [:])
        let live = try folder.write(currentData, to: "FilesLibrary.plist")
        let chosen = try folder.write(validList(ratings: ["/a.JPG": 1]), to: "chosen.plist")
        let broken = try folder.write(Data("broken".utf8), to: "broken.plist")
        let backups = folder.url.appendingPathComponent("backups")

        #expect(throws: ListWriter.WriteError.photomatorIsRunning) {
            try ListWriter.restore(chosen, to: live, backupFolder: backups, photomatorIsRunning: { true })
        }
        #expect(throws: PhotomatorList.ReadError.self) {
            try ListWriter.restore(broken, to: live, backupFolder: backups, photomatorIsRunning: { false })
        }
        #expect(try Data(contentsOf: live) == currentData)
    }

    /// Save may have changed a JPG since the list was made, so restore checks the photos against it.
    @Test func restoreFindsPhotosThatDifferFromTheListAndOnlyWritesThemWhenAsked() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let sidecar = try folder.write(Sample.sidecar(rating: 1, pick: 0), to: "r.xmp")
        try folder.write(Data(), to: "r.RAF")
        let same = try folder.write(Sample.sidecar(rating: 3), to: "same.xmp")
        try folder.write(Data(), to: "same.RAF")
        let unrelated = try folder.write(Sample.sidecar(rating: 2), to: "other.xmp")
        try folder.write(Data(), to: "other.RAF")

        let photos = PhotoScanner.photos(directlyIn: folder.url)
        let key = try #require(photos.first { $0.listKey.hasSuffix("/r.RAF") }).listKey
        let sameKey = try #require(photos.first { $0.listKey.hasSuffix("/same.RAF") }).listKey
        let gone = (key as NSString).deletingLastPathComponent + "/gone.RAF"
        let list = PhotomatorList(
            ratings: [key: 4, sameKey: 3, gone: 2], flags: [key: .reject], sidebarFolders: [folder.url.path]
        )

        let conflicts = Restorer.conflicts(with: list, photoKeys: [key, sameKey, gone])
        let conflict = try #require(conflicts.first)
        #expect(conflicts.count == 1)
        #expect(conflict.value == PhotoValue(stars: 4, flag: .reject))
        #expect(try XMPReader.value(inSidecar: sidecar).stars == 1)

        let result = try FileWriter.apply(conflicts, backupFolder: folder.url.appendingPathComponent("backups"))
        #expect(result.failures == [])
        #expect(try XMPReader.value(inSidecar: sidecar) == PhotoValue(stars: 4, flag: .reject))
        #expect(try XMPReader.value(inSidecar: same).stars == 3)
        #expect(try XMPReader.value(inSidecar: unrelated).stars == 2)
    }

    @Test func failuresAreSavedToAFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect(FailureLog.write([], to: folder.url) == nil)
        let file = try #require(FailureLog.write(
            [WriteFailure(file: URL(fileURLWithPath: "/a/b.JPG"), reason: "no")], to: folder.url
        ))
        #expect(try String(contentsOf: file, encoding: .utf8) == "/a/b.JPG\tno\n")
    }
}

/// A Debug build must never reach the real list.
struct DebugPathTests {
    @Test func debugBuildsUseTestLocations() {
        #expect(AppPaths.list.path.contains("Ratingmator-debug"))
        #expect(AppPaths.backups.path.contains("Ratingmator-debug"))
        #expect(!AppPaths.list.path.contains("Group Containers"))
    }
}
