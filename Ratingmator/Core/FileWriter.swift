import Darwin
import Foundation

nonisolated struct WriteFailure: Equatable, Sendable {
    let file: URL
    let reason: String
}

nonisolated struct WriteResult: Equatable, Sendable {
    var imagesWritten = 0
    var sidecarsWritten = 0
    var sidecarsCreated = 0
    var failures: [WriteFailure] = []
    var backup: URL?
}

/// Writes the decided values into the JPGs and sidecars (SPEC 6.1).
nonisolated enum FileWriter {
    enum WriteError: Error, Equatable {
        case backupFailed
    }

    /// Backs up the sidecars about to change, then writes each file that differs. If the backup
    /// fails nothing is written. A file that fails is reported and the others continue.
    static func apply(
        _ decisions: [PhotoDecision], backupFolder: URL, onProgress: (Int) -> Void = { _ in }
    ) throws -> WriteResult {
        var result = WriteResult()
        result.backup = try backUpSidecars(of: decisions, to: backupFolder)

        let exifTool = try ExifTool()
        defer { exifTool.close() }

        var done = 0
        for decision in decisions where !decision.isLeftAlone {
            if decision.changesImage, let image = decision.photo.imageURL {
                if let failure = write(decision.value, into: image, exifTool: exifTool) {
                    result.failures.append(failure)
                } else {
                    result.imagesWritten += 1
                }
                done += 1
                onProgress(done)
            }
            if decision.changesSidecar, let raw = decision.photo.rawURL {
                let failure: WriteFailure?
                if let sidecar = decision.photo.sidecarURL {
                    failure = write(decision.value, into: sidecar, exifTool: exifTool)
                    if failure == nil { result.sidecarsWritten += 1 }
                } else {
                    failure = createSidecar(for: raw, value: decision.value, exifTool: exifTool)
                    if failure == nil { result.sidecarsCreated += 1 }
                }
                if let failure { result.failures.append(failure) }
                done += 1
                onProgress(done)
            }
        }
        return result
    }

    // MARK: Writing

    /// The four fields Photomator writes (SPEC 3.2). A field with no final value is left alone.
    private static func fieldArguments(_ value: PhotoValue) -> [String] {
        var arguments: [String] = []
        if let stars = value.stars {
            arguments.append("-XMP-xmp:Rating=\(stars)")
        }
        if let flag = value.flag {
            arguments.append("-XMP-xmpDM:Pick=\(flag.rawValue)")
            switch flag {
            case .pick: arguments.append("-XMP-xmpDM:Good=True")
            case .reject: arguments.append("-XMP-xmpDM:Good=False")
            case .none: arguments.append("-XMP-xmpDM:Good=")
            }
        }
        arguments.append("-XMP-xmp:MetadataDate=now")
        return arguments
    }

    private static func write(_ value: PhotoValue, into file: URL, exifTool: ExifTool) -> WriteFailure? {
        let temporary = temporaryURL(for: file)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            // Keeps the XMP's toolkit name, which ExifTool would otherwise replace with its own.
            let printed = try exifTool.run(
                ["-o", temporary.path, "-tagsFromFile", "@", "-XMP-x:XMPToolkit"]
                    + fieldArguments(value) + [file.path]
            )
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                return WriteFailure(file: file, reason: firstLine(of: printed))
            }
            guard try holds(value, in: temporary) else {
                return WriteFailure(file: file, reason: "values not as written")
            }
            try copyAttributes(from: file, to: temporary)
            guard rename(temporary.path, file.path) == 0 else {
                return WriteFailure(file: file, reason: String(cString: strerror(errno)))
            }
            return nil
        } catch {
            return WriteFailure(file: file, reason: "\(error)")
        }
    }

    /// A new sidecar holds the RAW's camera data as well, as Photomator's do (SPEC 3.2). If that
    /// can't be read, the sidecar holds the four fields only.
    private static func createSidecar(for raw: URL, value: PhotoValue, exifTool: ExifTool) -> WriteFailure? {
        let sidecar = raw.deletingPathExtension().appendingPathExtension("xmp")
        let temporary = temporaryURL(for: sidecar)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            let cameraData = [
                "-tagsFromFile", raw.path,
                "-@", exifTool.argFiles.appendingPathComponent("exif2xmp.args").path,
                "-XMP-aux:Lens<LensModel",
                "-XMP-aux:LensInfo<LensInfo",
                "-XMP-aux:SerialNumber<SerialNumber",
                "-XMP-aux:LensSerialNumber<LensSerialNumber",
            ]
            let fields = fieldArguments(value)
            var printed = try exifTool.run(["-o", temporary.path] + cameraData + fields)
            if !FileManager.default.fileExists(atPath: temporary.path) {
                printed = try exifTool.run(["-o", temporary.path] + fields)
            }
            guard FileManager.default.fileExists(atPath: temporary.path) else {
                return WriteFailure(file: sidecar, reason: firstLine(of: printed))
            }
            guard try holds(value, in: temporary) else {
                return WriteFailure(file: sidecar, reason: "values not as written")
            }
            try FileManager.default.moveItem(at: temporary, to: sidecar)  // fails if one exists
            return nil
        } catch {
            return WriteFailure(file: sidecar, reason: "\(error)")
        }
    }

    /// Hidden, so a scan never sees it, and in the same folder, so the swap is a single rename.
    private static func temporaryURL(for file: URL) -> URL {
        let name = ".\(file.deletingPathExtension().lastPathComponent).ratingmator-tmp"
        return file.deletingLastPathComponent().appendingPathComponent(name)
            .appendingPathExtension(file.pathExtension)
    }

    /// Reads the new file back before it replaces anything.
    private static func holds(_ value: PhotoValue, in file: URL) throws -> Bool {
        let fileExtension = file.pathExtension.lowercased()
        let found: PhotoValue
        switch fileExtension {
        case "xmp": found = try XMPReader.value(inSidecar: file)
        case "jpg", "jpeg": found = try XMPReader.value(inJPEG: file)
        default: found = try XMPReader.value(inImage: file)
        }
        return !Determiner.differs(found, from: value)
    }

    /// Keeps the creation date, permissions, Finder tags and other extended attributes,
    /// which a new file wouldn't have.
    static func copyAttributes(from original: URL, to new: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        var kept: [FileAttributeKey: Any] = [:]
        kept[.creationDate] = attributes[.creationDate]
        kept[.posixPermissions] = attributes[.posixPermissions]
        try FileManager.default.setAttributes(kept, ofItemAtPath: new.path)
        guard copyfile(original.path, new.path, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func firstLine(of printed: String) -> String {
        printed.split(separator: "\n").first.map(String.init) ?? "not written"
    }

    // MARK: Backup

    /// A zip of every existing sidecar about to change, with its full path inside (SPEC 4.6).
    /// Returns nil if there's nothing to back up.
    private static func backUpSidecars(of decisions: [PhotoDecision], to folder: URL) throws -> URL? {
        let sidecars = decisions.compactMap { decision -> URL? in
            !decision.isLeftAlone && decision.changesSidecar ? decision.photo.sidecarURL : nil
        }
        guard !sidecars.isEmpty else { return nil }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("Ratingmator-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }

        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for sidecar in sidecars {
                let copy = staging.appendingPathComponent(sidecar.path)
                try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: sidecar, to: copy)
            }
            let zip = folder.appendingPathComponent("sidecars-\(timestamp())-\(UUID().uuidString.prefix(8)).zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", staging.path, zip.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0, manager.fileExists(atPath: zip.path) else {
                throw WriteError.backupFailed
            }
            return zip
        } catch {
            throw WriteError.backupFailed
        }
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
