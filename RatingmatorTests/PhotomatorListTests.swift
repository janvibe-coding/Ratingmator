import Foundation
import Testing
@testable import Ratingmator

struct PhotomatorListTests {
    private func validList() -> [String: Any] {
        [
            "version": 3,
            "directories": [["url": ["relative": "file:///Volumes/photos/to%20check%20jpg/"]]],
            "looseImages": [Any](),
            "flagsAndRatings": [
                "ratedAssets": ["/a/one.JPG": 3],
                "flaggedAssets": ["/a/one.JPG": 1, "/a/two.JPG": -1],
            ],
            "directoryOrder": [Any](),
            "displaysFolderContentsRecursively": true,
        ]
    }

    private func encode(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    @Test func readsRatingsFlagsAndSidebarFolders() throws {
        let list = try PhotomatorList(data: encode(validList()))
        #expect(list.ratings == ["/a/one.JPG": 3])
        #expect(list.flags == ["/a/one.JPG": .pick, "/a/two.JPG": .reject])
        #expect(list.sidebarFolders == ["/Volumes/photos/to check jpg"])
    }

    @Test func aPhotoWithoutEntryHasNoValue() throws {
        let list = try PhotomatorList(data: encode(validList()))
        #expect(list.value(forKey: "/a/one.JPG") == PhotoValue(stars: 3, flag: .pick))
        #expect(list.value(forKey: "/a/two.JPG") == PhotoValue(stars: nil, flag: .reject))
        #expect(list.value(forKey: "/a/three.JPG") == .empty)
    }

    @Test func comparesKeysNormalised() {
        let list = PhotomatorList(ratings: ["/Argentinie\u{0308}/a.JPG": 2], flags: [:], sidebarFolders: [])
        #expect(list.value(forKey: "/Argentini\u{00EB}/a.JPG").stars == 2)
        #expect(list.value(forKey: "/Argentinie\u{0308}/a.JPG").stars == 2)
    }

    @Test func refusesAnotherVersion() throws {
        var plist = validList()
        plist["version"] = 4
        #expect(throws: PhotomatorList.ReadError.unsupportedVersion) {
            try PhotomatorList(data: encode(plist))
        }
    }

    @Test(arguments: ["directories", "flagsAndRatings", "directoryOrder"])
    func refusesAMissingKey(key: String) throws {
        var plist = validList()
        plist[key] = nil
        #expect(throws: PhotomatorList.ReadError.self) {
            try PhotomatorList(data: encode(plist))
        }
    }

    @Test func refusesAnUnknownKey() throws {
        var plist = validList()
        plist["somethingNew"] = 1
        #expect(throws: PhotomatorList.ReadError.self) {
            try PhotomatorList(data: encode(plist))
        }
    }

    @Test(arguments: [0, 6, -1])
    func refusesAStarValueOutOfRange(stars: Int) throws {
        var plist = validList()
        plist["flagsAndRatings"] = ["ratedAssets": ["/a.JPG": stars], "flaggedAssets": [String: Int]()]
        #expect(throws: PhotomatorList.ReadError.self) {
            try PhotomatorList(data: encode(plist))
        }
    }

    @Test func refusesAnUnknownFlagValue() throws {
        var plist = validList()
        plist["flagsAndRatings"] = ["ratedAssets": [String: Int](), "flaggedAssets": ["/a.JPG": 2]]
        #expect(throws: PhotomatorList.ReadError.self) {
            try PhotomatorList(data: encode(plist))
        }
    }

    @Test func refusesSomethingElse() {
        #expect(throws: PhotomatorList.ReadError.notAPropertyList) {
            try PhotomatorList(data: Data("not a list".utf8))
        }
    }
}
