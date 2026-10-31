import Foundation
import Testing
@testable import Ratingmator

struct PhotoScannerTests {
    private func names(_ url: URL?) -> String? { url?.lastPathComponent }

    @Test func recognisesEveryKindOfPhoto() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Sample.jpeg(), to: "only.JPG")
        try folder.write(Data(), to: "raw.RAF")
        try folder.write(Data(), to: "negative.dng")
        try folder.write(Sample.jpeg(), to: "pair.JPG")
        try folder.write(Data(), to: "pair.RAF")
        try folder.write(Data("ignored".utf8), to: "notes.txt")

        let photos = try PhotoScanner.findPhotos(in: folder.url).photos
        let kinds = Dictionary(uniqueKeysWithValues: photos.map { ($0.listKey.split(separator: "/").last!, $0.kind) })
        #expect(kinds == ["only.JPG": .embedded, "raw.RAF": .rawOnly, "negative.dng": .dng, "pair.JPG": .pair])
    }

    @Test func aPairsKeyIsItsJPG() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Sample.jpeg(), to: "pair.JPG")
        try folder.write(Data(), to: "pair.RAF")
        let photo = try #require(PhotoScanner.findPhotos(in: folder.url).photos.first)
        #expect(names(photo.rawURL) == "pair.RAF")
        #expect(photo.listKey.hasSuffix("/pair.JPG"))
    }

    @Test(arguments: ["raw.xmp", "raw.XMP", "RAW.Xmp"])
    func findsASidecarWhateverItsCase(sidecar: String) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Data(), to: "raw.RAF")
        try folder.write(Sample.sidecar(rating: 2), to: sidecar)
        let photo = try #require(PhotoScanner.findPhotos(in: folder.url).photos.first)
        #expect(names(photo.sidecarURL) == sidecar)
        #expect(PhotoScanner.read(photo).sidecar == .value(PhotoValue(stars: 2, flag: nil)))
    }

    @Test func comparesNamesNormalisedAndKeepsTheOnDiskSpelling() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let decomposed = "Argentinie\u{0308}"
        let composed = "Argentini\u{00EB}"
        try folder.write(Data(), to: "\(decomposed)/\(decomposed).RAF")
        try folder.write(Sample.sidecar(rating: 1), to: "\(decomposed)/\(composed).xmp")

        let photo = try #require(PhotoScanner.findPhotos(in: folder.url).photos.first)
        #expect(photo.sidecarURL != nil)
        let expected = Array("/\(decomposed)/\(decomposed).RAF".unicodeScalars)
        #expect(Array(photo.listKey.unicodeScalars.suffix(expected.count)) == expected)
    }

    @Test func skipsHiddenFilesAndSidecarsWithoutAPhoto() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Data(), to: "._a.JPG")
        try folder.write(Data(), to: ".DS_Store")
        try folder.write(Sample.sidecar(rating: 1), to: "lonely.xmp")
        #expect(try PhotoScanner.findPhotos(in: folder.url).photos.isEmpty)
    }

    @Test func aFilesInSubfoldersAreSeparatePhotos() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Sample.jpeg(), to: "one/a.JPG")
        try folder.write(Data(), to: "two/a.RAF")
        let photos = try PhotoScanner.findPhotos(in: folder.url).photos
        #expect(photos.map(\.kind).sorted { "\($0)" < "\($1)" } == [.embedded, .rawOnly])
    }

    @Test func refusesAMissingFolder() {
        let missing = URL(fileURLWithPath: "/nonexistent-ratingmator-folder")
        #expect(throws: PhotoScanner.ScanError.notAFolder(missing)) {
            try PhotoScanner.scan(folders: [missing])
        }
    }

    @Test func aFolderInsideAnotherIsNotCountedTwice() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let nested = folder.url.appendingPathComponent("nested")
        try folder.write(Sample.jpeg(), to: "nested/a.JPG")
        let result = try PhotoScanner.scan(folders: [nested, folder.url, folder.url])
        #expect(result.folders.count == 1)
        #expect(result.counts.photos == 1)
    }

    @Test func countsAddUp() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Sample.jpeg(xmp: Sample.attributeXMP(rating: 3, pick: 1)), to: "a/complete.JPG")
        try folder.write(Sample.jpeg(xmp: Sample.sidecar(rating: 3)), to: "a/noflag.JPG")
        try folder.write(Sample.jpeg(), to: "a/nothing.JPG")
        try folder.write(Data("bad".utf8), to: "a/damaged.JPG")
        try folder.write(Data(), to: "b/nosidecar.RAF")
        try folder.write(Data(), to: "b/withsidecar.RAF")
        try folder.write(Sample.sidecar(rating: 1), to: "b/withsidecar.XMP")
        try folder.write(Data(), to: "b/negative.dng")
        try folder.write(Data("<bad".utf8), to: "b/negative.xmp")
        try folder.write(Sample.jpeg(), to: "b/pair.JPG")
        try folder.write(Data(), to: "b/pair.RAF")

        var progress = 0
        let result = try PhotoScanner.scan(
            folders: [folder.url.appendingPathComponent("a"), folder.url.appendingPathComponent("b")],
            onProgress: { progress = $0 }
        )

        var a = ScanCounts()
        a.photos = 4
        a.embedded = 4
        a.jpgsWithoutRating = 1
        a.jpgsWithoutFlag = 2
        a.unreadableFiles = 1
        #expect(result.folders[0].counts == a)

        var b = ScanCounts()
        b.photos = 4
        b.rawOnly = 2
        b.dng = 1
        b.pairs = 1
        b.missingSidecars = 2
        b.jpgsWithoutRating = 1
        b.jpgsWithoutFlag = 1
        b.unreadableFiles = 1
        #expect(result.folders[1].counts == b)

        #expect(result.counts.photos == 8)
        #expect(progress == 8)
    }

    @Test func stopsWhenCancelled() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(Sample.jpeg(), to: "a.JPG")
        let url = folder.url
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PhotoScanner.scan(folders: [url])
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
