import Foundation

/// One photo: the files that belong together in a folder (SPEC 5.1).
nonisolated struct Photo: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case embedded  // JPG, HEIC, PNG or TIFF: metadata inside the file
        case rawOnly
        case dng
        case pair  // RAW+JPEG
    }

    let kind: Kind
    /// The file that holds its metadata inside: JPG, HEIC, PNG or TIFF.
    let imageURL: URL?
    let rawURL: URL?
    let sidecarURL: URL?

    /// Photomator's key: a pair uses the JPG, anything else its own path (SPEC 6.2).
    var listKey: String { (imageURL ?? rawURL)!.path }

    /// The folder that directly holds this photo.
    var folderPath: String { (imageURL ?? rawURL)!.deletingLastPathComponent().path }
}

/// What reading a source gave.
nonisolated enum SourceRead: Equatable, Sendable {
    case absent  // this photo has no such file
    case value(PhotoValue)
    case unreadable
}

nonisolated struct ScannedPhoto: Equatable, Sendable {
    let photo: Photo
    let image: SourceRead
    let sidecar: SourceRead
}

nonisolated struct FolderScan: Equatable, Sendable {
    let folder: URL
    let photos: [ScannedPhoto]
    let unreadableFolders: [URL]

    var counts: ScanCounts { ScanCounts(photos) }
}

nonisolated struct ScanResult: Equatable, Sendable {
    let folders: [FolderScan]

    var counts: ScanCounts { ScanCounts(folders.flatMap(\.photos)) }
}

/// The counts a summary shows (SPEC 4.2).
nonisolated struct ScanCounts: Equatable, Sendable {
    var photos = 0
    var embedded = 0
    var rawOnly = 0
    var dng = 0
    var pairs = 0
    var missingSidecars = 0
    var jpgsWithoutRating = 0
    var jpgsWithoutFlag = 0
    var unreadableFiles = 0

    init() {}

    init(_ scanned: [ScannedPhoto]) {
        for item in scanned {
            photos += 1
            switch item.photo.kind {
            case .embedded: embedded += 1
            case .rawOnly: rawOnly += 1
            case .dng: dng += 1
            case .pair: pairs += 1
            }
            if item.photo.rawURL != nil, item.sidecar == .absent { missingSidecars += 1 }
            if case .value(let value) = item.image {
                if value.stars == nil { jpgsWithoutRating += 1 }
                if value.flag == nil { jpgsWithoutFlag += 1 }
            }
            if item.image == .unreadable { unreadableFiles += 1 }
            if item.sidecar == .unreadable { unreadableFiles += 1 }
        }
    }
}

/// Finds photos in folders and reads their values. Never writes.
nonisolated enum PhotoScanner {
    enum ScanError: Error, Equatable {
        case notAFolder(URL)
    }

    private static let rawExtensions: Set<String> = [
        "raf", "cr2", "cr3", "nef", "arw", "orf", "rw2", "pef", "srw",
    ]
    private static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    private static let otherImageExtensions: Set<String> = ["heic", "heif", "png", "tif", "tiff"]

    /// Reads every photo in the folders, subfolders included. Throws CancellationError when the
    /// surrounding Task is cancelled. onProgress gets the number of photos read so far.
    static func scan(folders: [URL], onProgress: (Int) -> Void = { _ in }) throws -> ScanResult {
        var done = 0
        let results = try outermost(folders).map { folder -> FolderScan in
            let (photos, unreadableFolders) = try findPhotos(in: folder)
            let scanned = try photos.map { photo -> ScannedPhoto in
                try Task.checkCancellation()
                let item = autoreleasepool { read(photo) }
                done += 1
                onProgress(done)
                return item
            }
            return FolderScan(folder: folder, photos: scanned, unreadableFolders: unreadableFolders)
        }
        return ScanResult(folders: results)
    }

    static func findPhotos(in folder: URL) throws -> (photos: [Photo], unreadableFolders: [URL]) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ScanError.notAFolder(folder)
        }

        var unreadableFolders: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                unreadableFolders.append(url)
                return true
            }
        )

        var filesByFolder: [String: [URL]] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            filesByFolder[url.deletingLastPathComponent().path, default: []].append(url)
        }

        let photos = filesByFolder.keys.sorted().flatMap { photos(among: filesByFolder[$0]!) }
        return (photos, unreadableFolders)
    }

    static func read(_ photo: Photo) -> ScannedPhoto {
        var image = SourceRead.absent
        if let url = photo.imageURL {
            let isJPG = jpgExtensions.contains(url.pathExtension.lowercased())
            image = source { try isJPG ? XMPReader.value(inJPEG: url) : XMPReader.value(inImage: url) }
        }
        var sidecar = SourceRead.absent
        if let url = photo.sidecarURL {
            sidecar = source { try XMPReader.value(inSidecar: url) }
        }
        return ScannedPhoto(photo: photo, image: image, sidecar: sidecar)
    }

    private static func source(_ reading: () throws -> PhotoValue) -> SourceRead {
        guard let value = try? reading() else { return .unreadable }
        return .value(value)
    }

    /// The photos directly in one folder, not in its subfolders.
    static func photos(directlyIn folder: URL) -> [Photo] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return photos(among: files.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        })
    }

    /// Groups one folder's files by name. Names compare case-insensitively and Unicode-normalised;
    /// the URLs keep the on-disk spelling (SPEC 8.7).
    private static func photos(among files: [URL]) -> [Photo] {
        struct Group {
            var raws: [URL] = []
            var jpgs: [URL] = []
            var otherImages: [URL] = []
            var sidecars: [URL] = []
        }

        var groups: [String: Group] = [:]
        for file in files.sorted(by: { $0.path < $1.path }) {
            let name = file.deletingPathExtension().lastPathComponent
                .precomposedStringWithCanonicalMapping.lowercased()
            let fileExtension = file.pathExtension.lowercased()
            if rawExtensions.contains(fileExtension) || fileExtension == "dng" {
                groups[name, default: Group()].raws.append(file)
            } else if jpgExtensions.contains(fileExtension) {
                groups[name, default: Group()].jpgs.append(file)
            } else if otherImageExtensions.contains(fileExtension) {
                groups[name, default: Group()].otherImages.append(file)
            } else if fileExtension == "xmp" {
                groups[name, default: Group()].sidecars.append(file)
            }
        }

        var photos: [Photo] = []
        for name in groups.keys.sorted() {
            var group = groups[name]!
            let sidecar = group.sidecars.first
            if !group.raws.isEmpty, !group.jpgs.isEmpty {
                photos.append(Photo(
                    kind: .pair, imageURL: group.jpgs.removeFirst(), rawURL: group.raws.removeFirst(), sidecarURL: sidecar
                ))
            }
            for raw in group.raws {
                let kind: Photo.Kind = raw.pathExtension.lowercased() == "dng" ? .dng : .rawOnly
                photos.append(Photo(kind: kind, imageURL: nil, rawURL: raw, sidecarURL: sidecar))
            }
            for image in group.jpgs + group.otherImages {
                photos.append(Photo(kind: .embedded, imageURL: image, rawURL: nil, sidecarURL: nil))
            }
        }
        return photos
    }

    /// A folder inside another chosen folder is already covered by that one.
    private static func outermost(_ folders: [URL]) -> [URL] {
        func withSlash(_ url: URL) -> String { url.path.hasSuffix("/") ? url.path : url.path + "/" }
        var unique: [URL] = []
        for folder in folders where !unique.contains(where: { withSlash($0) == withSlash(folder) }) {
            unique.append(folder)
        }
        return unique.filter { folder in
            !unique.contains { $0 != folder && withSlash(folder).hasPrefix(withSlash($0)) }
        }
    }
}
