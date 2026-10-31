import Foundation

/// An earlier list in the backup folder.
nonisolated struct ListBackup: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date
    let ratings: Int
    let flags: Int

    var id: URL { url }

    /// The lists in a backup folder, newest first. A file that isn't a readable list is left out.
    static func all(in folder: URL) -> [ListBackup] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("FilesLibrary-") && $0.pathExtension == "plist" }
            .compactMap { url -> ListBackup? in
                guard let list = try? PhotomatorList(contentsOf: url) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return ListBackup(url: url, date: date ?? .distantPast, ratings: list.ratings.count, flags: list.flags.count)
            }
            .sorted { $0.date > $1.date }
    }
}

/// What putting an earlier list back would do (SPEC 4.4).
nonisolated struct RestoreComparison: Equatable, Sendable {
    var changes = ListChanges()
    var sidebarFoldersAdded: [String] = []
    var sidebarFoldersRemoved: [String] = []
    var missingPhotos = 0
    var missingFolders: [String] = []
    /// The photos that exist and have an entry in the chosen list.
    var photosInList: [String] = []

    init(chosen: PhotomatorList, current: PhotomatorList, exists: (String) -> Bool) {
        for (key, value) in chosen.ratings {
            if let old = current.ratings[key] {
                if old != value { changes.ratingsChanged += 1 }
            } else {
                changes.ratingsAdded += 1
            }
        }
        changes.ratingsRemoved = current.ratings.keys.filter { chosen.ratings[$0] == nil }.count

        for (key, value) in chosen.flags {
            if let old = current.flags[key] {
                if old != value { changes.flagsChanged += 1 }
            } else {
                changes.flagsAdded += 1
            }
        }
        changes.flagsRemoved = current.flags.keys.filter { chosen.flags[$0] == nil }.count

        let chosenFolders = Set(chosen.sidebarFolders)
        let currentFolders = Set(current.sidebarFolders)
        sidebarFoldersAdded = chosenFolders.subtracting(currentFolders).sorted()
        sidebarFoldersRemoved = currentFolders.subtracting(chosenFolders).sorted()
        missingFolders = chosen.sidebarFolders.filter { !exists($0) }.sorted()

        for key in Set(chosen.ratings.keys).union(chosen.flags.keys).sorted() {
            if exists(key) {
                photosInList.append(key)
            } else {
                missingPhotos += 1
            }
        }
    }
}

nonisolated enum Restorer {
    /// The photos in the list whose files hold something else, with what writing the list's value would do.
    /// They're only written if chosen: the check exists because Save may have changed a JPG
    /// since this list was made (SPEC 4.4).
    static func conflicts(with list: PhotomatorList, photoKeys: [String]) -> [PhotoDecision] {
        let wanted = Set(photoKeys.map { $0.precomposedStringWithCanonicalMapping })
        let folders = Set(photoKeys.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })

        var conflicts: [PhotoDecision] = []
        for folder in folders.sorted() {
            for photo in PhotoScanner.photos(directlyIn: URL(fileURLWithPath: folder)) {
                let key = photo.listKey
                guard wanted.contains(key.precomposedStringWithCanonicalMapping) else { continue }
                let listValue = list.value(forKey: key)
                let value = PhotoValue(stars: listValue.stars ?? 0, flag: listValue.flag ?? Flag.none)
                let decision = Determiner.decide(PhotoScanner.read(photo), setting: value)
                guard !decision.isSkipped, decision.changesImage || decision.changesSidecar else { continue }
                conflicts.append(decision)
            }
        }
        return conflicts
    }
}
