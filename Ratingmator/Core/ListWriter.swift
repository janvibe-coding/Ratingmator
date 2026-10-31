import AppKit
import Darwin
import Foundation

/// What a list write adds, changes and removes, for the summary (SPEC 4.3).
nonisolated struct ListChanges: Equatable, Sendable {
    var ratingsAdded = 0
    var ratingsChanged = 0
    var ratingsRemoved = 0
    var flagsAdded = 0
    var flagsChanged = 0
    var flagsRemoved = 0

    var isEmpty: Bool { self == ListChanges() }
}

/// The list's new contents and how they differ from the old.
nonisolated struct ListPlan: Equatable, Sendable {
    let ratings: [String: Int]
    let flags: [String: Int]
    let changes: ListChanges
}

nonisolated struct ListWriteResult: Equatable, Sendable {
    let changes: ListChanges
    /// nil when nothing needed writing.
    let backup: URL?
}

/// Writes decided values to Photomator's list (SPEC 6.2, 8). Only flagsAndRatings ever changes.
nonisolated enum ListWriter {
    enum WriteError: Error, Equatable {
        case photomatorIsRunning
        case backupFailed
        case writeFailed
        /// The list didn't check out and the backup is back in place.
        case verificationFailed
        /// The list didn't check out and the backup couldn't be put back.
        case restoreFailed(backup: URL)
    }

    static let photomatorBundleID = "com.pixelmatorteam.pixelmator.touch.x.photo"

    static func photomatorIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: photomatorBundleID).isEmpty
    }

    // MARK: Planning

    /// Works out the new entries. Only photos inside a sidebar folder take part, and a field with
    /// no final value is left as it is, as is every entry for a photo not in these decisions.
    static func plan(_ decisions: [PhotoDecision], list: PhotomatorList) -> ListPlan {
        var ratings = Entries(list.ratings)
        var flags = Entries(list.flags.mapValues(\.rawValue))
        var changes = ListChanges()
        let folders = list.sidebarFolders.map { normalized($0.hasSuffix("/") ? $0 : $0 + "/") }

        for decision in decisions where !decision.isLeftAlone {
            let key = decision.photo.listKey
            let normalizedKey = normalized(key)
            guard folders.contains(where: { normalizedKey.hasPrefix($0) }) else { continue }

            if let stars = decision.value.stars {
                switch ratings.set(stars, forKey: key) {
                case .added: changes.ratingsAdded += 1
                case .changed: changes.ratingsChanged += 1
                case .removed: changes.ratingsRemoved += 1
                case .same: break
                }
            }
            if let flag = decision.value.flag {
                switch flags.set(flag.rawValue, forKey: key) {
                case .added: changes.flagsAdded += 1
                case .changed: changes.flagsChanged += 1
                case .removed: changes.flagsRemoved += 1
                case .same: break
                }
            }
        }
        return ListPlan(ratings: ratings.values, flags: flags.values, changes: changes)
    }

    private static func normalized(_ key: String) -> String {
        key.precomposedStringWithCanonicalMapping
    }

    /// A list's entries, found by normalised key and written in the on-disk spelling (SPEC 8.7).
    /// 0 means no entry: stars 0 and no flag are both written by removing it.
    private struct Entries {
        enum Outcome { case added, changed, removed, same }

        private(set) var values: [String: Int]
        private var spellings: [String: String]

        init(_ values: [String: Int]) {
            self.values = values
            spellings = Dictionary(
                values.keys.map { (normalized($0), $0) }, uniquingKeysWith: { first, _ in first }
            )
        }

        mutating func set(_ value: Int, forKey key: String) -> Outcome {
            let normalizedKey = normalized(key)
            let existingKey = spellings[normalizedKey]
            let existingValue = existingKey.flatMap { values[$0] }

            if value == 0 {
                guard let existingKey else { return .same }
                values[existingKey] = nil
                spellings[normalizedKey] = nil
                return .removed
            }
            if existingValue == value, existingKey.map({ $0.unicodeScalars.elementsEqual(key.unicodeScalars) }) == true {
                return .same
            }
            if let existingKey { values[existingKey] = nil }
            values[key] = value
            spellings[normalizedKey] = key
            return existingKey == nil ? .added : .changed
        }
    }

    // MARK: Writing

    /// Backs up the list, swaps in the new one and checks it. On a failed check the backup goes back.
    /// afterWrite runs between the swap and the check; only tests use it, to damage the result.
    @discardableResult
    static func apply(
        _ decisions: [PhotoDecision],
        to listURL: URL,
        backupFolder: URL,
        photomatorIsRunning isRunning: () -> Bool = photomatorIsRunning,
        afterWrite: (URL) throws -> Void = { _ in }
    ) throws -> ListWriteResult {
        guard !isRunning() else { throw WriteError.photomatorIsRunning }

        let originalData = try Data(contentsOf: listURL)
        let list = try PhotomatorList(data: originalData)
        let plan = plan(decisions, list: list)
        guard !plan.changes.isEmpty else { return ListWriteResult(changes: plan.changes, backup: nil) }

        let backup = try backUp(originalData, to: backupFolder)
        try swapIn(try newContents(of: originalData, plan: plan), at: listURL)

        do {
            try afterWrite(listURL)
            try verify(listURL, original: originalData, plan: plan)
        } catch {
            do {
                try swapIn(originalData, at: listURL)
            } catch {
                throw WriteError.restoreFailed(backup: backup)
            }
            throw WriteError.verificationFailed
        }
        return ListWriteResult(changes: plan.changes, backup: backup)
    }

    /// Restore backup: puts a whole earlier list back, sidebar folders included (SPEC 4.4, 8.2).
    /// The current list is backed up first. Returns that backup.
    @discardableResult
    static func restore(
        _ chosen: URL,
        to listURL: URL,
        backupFolder: URL,
        photomatorIsRunning isRunning: () -> Bool = photomatorIsRunning
    ) throws -> URL {
        guard !isRunning() else { throw WriteError.photomatorIsRunning }
        let current = try Data(contentsOf: listURL)
        let new = try Data(contentsOf: chosen)
        _ = try PhotomatorList(data: new)

        let backup = try backUp(current, to: backupFolder)
        try swapIn(new, at: listURL)
        guard (try? Data(contentsOf: listURL)) == new else {
            do {
                try swapIn(current, at: listURL)
            } catch {
                throw WriteError.restoreFailed(backup: backup)
            }
            throw WriteError.verificationFailed
        }
        return backup
    }

    private static func newContents(of originalData: Data, plan: ListPlan) throws -> Data {
        guard var root = try PropertyListSerialization.propertyList(from: originalData, format: nil) as? [String: Any],
              var flagsAndRatings = root["flagsAndRatings"] as? [String: Any] else {
            throw WriteError.writeFailed
        }
        flagsAndRatings["ratedAssets"] = plan.ratings
        flagsAndRatings["flaggedAssets"] = plan.flags
        root["flagsAndRatings"] = flagsAndRatings
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// A dated copy that's kept, read back to make sure it holds the same bytes (SPEC 4.6).
    private static func backUp(_ data: Data, to folder: URL) throws -> URL {
        let backup = folder.appendingPathComponent(
            "FilesLibrary-\(FileWriter.timestamp())-\(UUID().uuidString.prefix(8)).plist"
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: backup, options: .withoutOverwriting)
            guard try Data(contentsOf: backup) == data else { throw WriteError.backupFailed }
            return backup
        } catch {
            throw WriteError.backupFailed
        }
    }

    /// Through a temporary file in the same folder, so the swap is a single rename.
    private static func swapIn(_ data: Data, at listURL: URL) throws {
        let temporary = listURL.deletingLastPathComponent()
            .appendingPathComponent(".\(listURL.lastPathComponent).ratingmator-tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary)
            try FileWriter.copyAttributes(from: listURL, to: temporary)
            guard rename(temporary.path, listURL.path) == 0 else { throw WriteError.writeFailed }
        } catch {
            throw WriteError.writeFailed
        }
    }

    /// SPEC 8.5: valid, all other keys unchanged, and exactly the planned entries.
    private static func verify(_ listURL: URL, original: Data, plan: ListPlan) throws {
        let written = try Data(contentsOf: listURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var writtenRoot = try PropertyListSerialization.propertyList(from: written, format: &format) as? [String: Any],
              format == .binary,
              var originalRoot = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
              var writtenFlagsAndRatings = writtenRoot["flagsAndRatings"] as? [String: Any],
              var originalFlagsAndRatings = originalRoot["flagsAndRatings"] as? [String: Any],
              writtenFlagsAndRatings["ratedAssets"] as? [String: Int] == plan.ratings,
              writtenFlagsAndRatings["flaggedAssets"] as? [String: Int] == plan.flags else {
            throw WriteError.verificationFailed
        }
        _ = try PhotomatorList(data: written)

        for key in ["ratedAssets", "flaggedAssets"] {
            writtenFlagsAndRatings[key] = nil
            originalFlagsAndRatings[key] = nil
        }
        writtenRoot["flagsAndRatings"] = writtenFlagsAndRatings
        originalRoot["flagsAndRatings"] = originalFlagsAndRatings
        guard isIdentical(writtenRoot, originalRoot) else { throw WriteError.verificationFailed }
    }

    /// Compares two property lists exactly: a value's type counts too, so a true doesn't pass for a 1.
    static func isIdentical(_ first: Any, _ second: Any) -> Bool {
        if let first = first as? [String: Any], let second = second as? [String: Any] {
            return first.count == second.count && first.allSatisfy { key, value in
                second[key].map { isIdentical(value, $0) } ?? false
            }
        }
        if let first = first as? [Any], let second = second as? [Any] {
            return first.count == second.count && zip(first, second).allSatisfy { isIdentical($0, $1) }
        }
        let a = first as AnyObject
        let b = second as AnyObject
        return CFGetTypeID(a) == CFGetTypeID(b) && a.isEqual(b)
    }
}
