import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Ratingmator

/// Writes a small real JPEG holding the given rating, so ExifTool has a valid file to work on.
private func makeJPEG(at url: URL, stars: Int? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = try #require(CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let metadata = CGImageMetadataCreateMutable()
    if let stars {
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "\(stars)" as CFString))
    }
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func decision(
    _ photo: Photo, value: PhotoValue, image: Bool = false, sidecar: Bool = false, skipped: Bool = false
) -> PhotoDecision {
    PhotoDecision(
        photo: photo, sources: PhotoSources(), conflict: nil, value: value,
        changesImage: image, changesSidecar: sidecar, isSkipped: skipped
    )
}

private func backupFolder(_ folder: TemporaryFolder) -> URL {
    folder.url.appendingPathComponent("backups")
}

struct ExifToolTests {
    @Test func theBundledCopyRunsWithMacOSPerl() throws {
        let tool = try ExifTool()
        defer { tool.close() }
        #expect(try tool.run(["-ver"]).trimmingCharacters(in: .whitespacesAndNewlines) == "13.60")
    }

    @Test func itStaysRunningBetweenCommands() throws {
        let tool = try ExifTool()
        defer { tool.close() }
        #expect(try tool.run(["-ver"]) == tool.run(["-ver"]))
    }
}

struct FileWriterTests {
    private func jpgPhoto(_ url: URL) -> Photo {
        Photo(kind: .embedded, imageURL: url, rawURL: nil, sidecarURL: nil)
    }

    @Test(arguments: [
        (PhotoValue(stars: 3, flag: .pick), "True"),
        (PhotoValue(stars: 1, flag: .reject), "False"),
    ])
    func writesStarsAndFlagIntoAJPG(value: PhotoValue, good: String) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appendingPathComponent("a.JPG")
        try makeJPEG(at: file)

        let result = try FileWriter.apply(
            [decision(jpgPhoto(file), value: value, image: true)], backupFolder: backupFolder(folder)
        )
        #expect(result.failures == [])
        #expect(result.imagesWritten == 1)
        #expect(try XMPReader.value(inJPEG: file) == value)

        let tool = try ExifTool()
        defer { tool.close() }
        #expect(try tool.run(["-s3", "-XMP-xmpDM:Good", file.path]).contains(good))
        #expect(try tool.run(["-s3", "-XMP-xmp:MetadataDate", file.path]).contains(":"))
    }

    @Test func noFlagWritesPickZeroAndRemovesGood() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let raw = try folder.write(Data(), to: "a.RAF")
        let sidecar = try folder.write(Sample.attributeXMP(rating: 2, pick: 1), to: "a.xmp")
        let photo = Photo(kind: .rawOnly, imageURL: nil, rawURL: raw, sidecarURL: sidecar)

        let result = try FileWriter.apply(
            [decision(photo, value: PhotoValue(stars: 0, flag: Flag.none), sidecar: true)],
            backupFolder: backupFolder(folder)
        )
        #expect(result.failures == [])
        #expect(try XMPReader.value(inSidecar: sidecar) == PhotoValue(stars: 0, flag: Flag.none))
        #expect(!String(decoding: try Data(contentsOf: sidecar), as: UTF8.self).contains("xmpDM:good"))
    }

    @Test func aFieldWithoutAFinalValueIsLeftAlone() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let raw = try folder.write(Data(), to: "a.RAF")
        let sidecar = try folder.write(Sample.sidecar(rating: 2, pick: 1), to: "a.xmp")
        let photo = Photo(kind: .rawOnly, imageURL: nil, rawURL: raw, sidecarURL: sidecar)

        _ = try FileWriter.apply(
            [decision(photo, value: PhotoValue(stars: 4, flag: nil), sidecar: true)],
            backupFolder: backupFolder(folder)
        )
        #expect(try XMPReader.value(inSidecar: sidecar) == PhotoValue(stars: 4, flag: .pick))
    }

    @Test func keepsCreationDatePermissionsAndFinderTags() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appendingPathComponent("a.JPG")
        try makeJPEG(at: file)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let modified = Date(timeIntervalSince1970: 1_100_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: file.path
        )
        var url = file
        try (url as NSURL).setResourceValue(["Keep"], forKey: .tagNamesKey)

        _ = try FileWriter.apply(
            [decision(jpgPhoto(file), value: PhotoValue(stars: 2, flag: nil), image: true)],
            backupFolder: backupFolder(folder)
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.creationDate] as? Date == created)
        #expect(attributes[.posixPermissions] as? Int == 0o640)
        #expect((attributes[.modificationDate] as? Date ?? modified) > modified)
        url.removeAllCachedResourceValues()
        #expect(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Keep"])
    }

    @Test func keepsASidecarsNameAndAnAccentedFolderAsTheyAre() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let raw = try folder.write(Data(), to: "Argentinie\u{0308}/a.RAF")
        let sidecar = try folder.write(Sample.sidecar(rating: 1), to: "Argentinie\u{0308}/a.XMP")
        let photo = Photo(kind: .rawOnly, imageURL: nil, rawURL: raw, sidecarURL: sidecar)

        let result = try FileWriter.apply(
            [decision(photo, value: PhotoValue(stars: 5, flag: nil), sidecar: true)],
            backupFolder: backupFolder(folder)
        )
        #expect(result.failures == [])
        #expect(result.sidecarsWritten == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: sidecar.deletingLastPathComponent().path)
        #expect(names.sorted() == ["a.RAF", "a.XMP"])
        #expect(try XMPReader.value(inSidecar: sidecar).stars == 5)
    }

    @Test func aRAWThatCannotBeReadStillGetsASidecarWithTheFields() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let raw = try folder.write(Data("not a raw".utf8), to: "a.RAF")
        let photo = Photo(kind: .rawOnly, imageURL: nil, rawURL: raw, sidecarURL: nil)

        let result = try FileWriter.apply(
            [decision(photo, value: PhotoValue(stars: 2, flag: .pick), sidecar: true)],
            backupFolder: backupFolder(folder)
        )
        #expect(result.failures == [])
        #expect(result.sidecarsCreated == 1)
        let sidecar = folder.url.appendingPathComponent("a.xmp")
        #expect(try XMPReader.value(inSidecar: sidecar) == PhotoValue(stars: 2, flag: .pick))
    }

    @Test func aPairsNewSidecarGoesNextToItsRAW() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let jpg = folder.url.appendingPathComponent("a.JPG")
        try makeJPEG(at: jpg, stars: 2)
        let raw = try folder.write(Data(), to: "a.RAF")
        let before = try Data(contentsOf: jpg)
        let photo = Photo(kind: .pair, imageURL: jpg, rawURL: raw, sidecarURL: nil)

        let result = try FileWriter.apply(
            [decision(photo, value: PhotoValue(stars: 2, flag: nil), sidecar: true)],
            backupFolder: backupFolder(folder)
        )
        #expect(result.sidecarsCreated == 1)
        #expect(result.imagesWritten == 0)
        #expect(try Data(contentsOf: jpg) == before)
        #expect(try XMPReader.value(inSidecar: folder.url.appendingPathComponent("a.xmp")).stars == 2)
    }

    @Test func aFileThatDoesNotDifferOrASkippedPhotoIsNotTouched() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let unchanged = folder.url.appendingPathComponent("a.JPG")
        let skipped = folder.url.appendingPathComponent("b.JPG")
        try makeJPEG(at: unchanged, stars: 1)
        try makeJPEG(at: skipped, stars: 1)
        let before = try Data(contentsOf: unchanged)

        let result = try FileWriter.apply([
            decision(jpgPhoto(unchanged), value: PhotoValue(stars: 1, flag: nil)),
            decision(jpgPhoto(skipped), value: PhotoValue(stars: 5, flag: nil), image: true, skipped: true),
        ], backupFolder: backupFolder(folder))

        #expect(result == WriteResult())
        #expect(try Data(contentsOf: unchanged) == before)
        #expect(try XMPReader.value(inJPEG: skipped).stars == 1)
    }

    @Test func aFailureIsReportedTheOthersContinueAndNothingIsLeftBehind() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let damaged = try folder.write(Data("not a jpeg".utf8), to: "bad.JPG")
        let good = folder.url.appendingPathComponent("good.JPG")
        try makeJPEG(at: good)

        var progress = 0
        let result = try FileWriter.apply([
            decision(jpgPhoto(damaged), value: PhotoValue(stars: 3, flag: nil), image: true),
            decision(jpgPhoto(good), value: PhotoValue(stars: 3, flag: nil), image: true),
        ], backupFolder: backupFolder(folder), onProgress: { progress = $0 })

        #expect(result.failures.map(\.file) == [damaged])
        #expect(result.imagesWritten == 1)
        #expect(progress == 2)
        #expect(try Data(contentsOf: damaged) == Data("not a jpeg".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names.sorted() == ["bad.JPG", "good.JPG"])
    }
}

struct BackupTests {
    private func sidecarPhoto(_ folder: TemporaryFolder, name: String, rating: Int) throws -> Photo {
        let raw = try folder.write(Data(), to: "\(name).RAF")
        let sidecar = try folder.write(Sample.sidecar(rating: rating), to: "\(name).xmp")
        return Photo(kind: .rawOnly, imageURL: nil, rawURL: raw, sidecarURL: sidecar)
    }

    @Test func aZipOfTheOldSidecarsIsMadeWithTheirFullPaths() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let changes = try sidecarPhoto(folder, name: "changes", rating: 1)
        let stays = try sidecarPhoto(folder, name: "stays", rating: 1)

        let result = try FileWriter.apply([
            decision(changes, value: PhotoValue(stars: 4, flag: nil), sidecar: true),
            decision(stays, value: PhotoValue(stars: 1, flag: nil)),
        ], backupFolder: backupFolder(folder))

        let zip = try #require(result.backup)
        #expect(zip.lastPathComponent.hasPrefix("sidecars-"))

        let unpacked = folder.url.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()

        let saved = unpacked.appendingPathComponent(try #require(changes.sidecarURL).path)
        #expect(try XMPReader.value(inSidecar: saved).stars == 1)
        #expect(!FileManager.default.fileExists(atPath: unpacked.appendingPathComponent(stays.sidecarURL!.path).path))
    }

    @Test func noSidecarToChangeMeansNoZip() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let raw = try folder.write(Data(), to: "a.RAF")
        let photo = Photo(kind: .rawOnly, imageURL: nil, rawURL: raw, sidecarURL: nil)
        let result = try FileWriter.apply(
            [decision(photo, value: PhotoValue(stars: 2, flag: nil), sidecar: true)],
            backupFolder: backupFolder(folder)
        )
        #expect(result.backup == nil)
        #expect(result.sidecarsCreated == 1)
    }

    @Test func ifTheBackupFailsNothingIsWritten() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let photo = try sidecarPhoto(folder, name: "a", rating: 1)
        let notAFolder = try folder.write(Data(), to: "backups")

        #expect(throws: FileWriter.WriteError.backupFailed) {
            try FileWriter.apply(
                [decision(photo, value: PhotoValue(stars: 4, flag: nil), sidecar: true)],
                backupFolder: notAFolder
            )
        }
        #expect(try XMPReader.value(inSidecar: photo.sidecarURL!).stars == 1)
    }
}
