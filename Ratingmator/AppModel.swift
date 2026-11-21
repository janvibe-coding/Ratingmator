import AppKit
import Combine
import Foundation

enum Screen: Equatable {
    case noAccess
    case photomatorOpen
    case start
    case chooseSave
    case chooseLoad
    case working
    case summary
    case applying
    case result
    case chooseRestore
    case restoreSummary
}

enum Flow: Equatable {
    case save
    case load
    case restore
}

final class AppModel: ObservableObject {
    @Published var screen = Screen.start
    @Published var message: String?
    @Published var isQuittingPhotomator = false
    @Published private(set) var flow = Flow.save

    // Save: choose
    @Published var droppedFolders: [URL] = []

    // Load: the sidebar folders to choose from, and the folders this Load covers
    @Published private(set) var sidebarFolders: [PickableFolder] = []
    @Published private(set) var loadedFolders: [URL] = []

    // Scan
    @Published private(set) var scanned = 0
    private var scanTask: Task<Void, Never>?

    // Summary
    @Published private(set) var scan: ScanResult?
    @Published private(set) var list: PhotomatorList?
    @Published private(set) var determination: Determination?
    @Published private(set) var listChanges = ListChanges()
    @Published private(set) var listUpdatedPhotos = 0
    @Published var settings = ConflictSettings() {
        didSet { recalculate() }
    }
    @Published var writeSettings = WriteSettings() {
        didSet { applyWriteSettings() }
    }
    /// The decisions before the write choices: those choices change no value, tree or list entry,
    /// so a click in the Changes section only has to mark writes again.
    private var undecidedWrites: Determination?
    @Published private(set) var conflictFolders: [ConflictType: [FolderNode<Int>]] = [:]
    @Published private(set) var writeFolders: [WriteKind: [FolderNode<Int>]] = [:]
    @Published private(set) var folderRatings: [FolderNode<RatingTable.Row>] = []
    /// What the separate window shows: a conflict type or a kind of write, and its folders if not all.
    /// Only its rows are kept; the window builds just the page it shows.
    @Published private(set) var windowConflict: ConflictType?
    @Published private(set) var windowWrite: WriteKind?
    @Published private(set) var windowFolders: Set<String>?
    @Published private(set) var windowPhotos: [PhotoDecision] = []

    // Apply and result
    @Published private(set) var applied = 0
    @Published private(set) var resultLines: [String] = []
    @Published private(set) var failureLog: URL?

    // Restore
    @Published private(set) var backups: [ListBackup] = []
    @Published private(set) var chosenBackup: ListBackup?
    @Published private(set) var restoreComparison: RestoreComparison?
    @Published private(set) var restoreConflicts: [PhotoDecision] = []
    @Published var restoreWritesPhotos = false

    var hasBackups: Bool { !ListBackup.all(in: AppPaths.backups).isEmpty }

    // MARK: Launch and Photomator

    func launchCheck() {
        if !FullDiskAccess.isGranted {
            screen = .noAccess
        } else if Photomator.isRunning {
            screen = .photomatorOpen
        } else if screen == .noAccess || screen == .photomatorOpen {
            screen = .start
        }
    }

    func quitPhotomator() {
        isQuittingPhotomator = true
        Task {
            let closed = await Photomator.quit()
            isQuittingPhotomator = false
            if closed {
                launchCheck()
            } else {
                message = "Photomator didn't quit within 30 seconds."
            }
        }
    }

    /// Before every Apply: Photomator may have been reopened. Runs the action once it's closed.
    private func withPhotomatorClosed(_ action: @escaping () -> Void) {
        guard Photomator.isRunning else {
            action()
            return
        }
        isQuittingPhotomator = true
        Task {
            let closed = await Photomator.quit()
            isQuittingPhotomator = false
            if closed {
                action()
            } else {
                message = "Photomator didn't quit within 30 seconds."
            }
        }
    }

    func backToStart() {
        scanTask?.cancel()
        scan = nil
        list = nil
        determination = nil
        listChanges = ListChanges()
        listUpdatedPhotos = 0
        settings = ConflictSettings()
        writeSettings = WriteSettings()
        windowConflict = nil
        windowWrite = nil
        windowFolders = nil
        windowPhotos = []
        conflictFolders = [:]
        writeFolders = [:]
        loadedFolders = []
        folderRatings = []
        droppedFolders = []
        resultLines = []
        failureLog = nil
        chosenBackup = nil
        restoreComparison = nil
        restoreConflicts = []
        restoreWritesPhotos = false
        screen = .start
        launchCheck()
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    func openPhotomatorAndQuit() {
        Photomator.open()
        NSApp.terminate(nil)
    }

    // MARK: Choose

    func startSave() {
        flow = .save
        screen = .chooseSave
    }

    func addDropped(_ urls: [URL]) {
        for url in urls where !droppedFolders.contains(url) {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                droppedFolders.append(url)
            }
        }
    }

    func scanDroppedFolders() {
        startScan(folders: droppedFolders, returnTo: .chooseSave)
    }

    /// Load scans the sidebar folders that are connected (SPEC 4.3), or only the folders chosen.
    func startLoad() {
        flow = .load
        guard let loaded = readList() else { return }
        let folders = loaded.sidebarFolders
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
        guard !folders.isEmpty else {
            message = "None of Photomator's sidebar folders is connected."
            return
        }
        loadedFolders = []
        startScan(folders: folders, returnTo: .start)
    }

    func chooseLoadFolders() {
        flow = .load
        guard let loaded = readList() else { return }
        sidebarFolders = loaded.sidebarFolders.sorted().map { path in
            PickableFolder(url: URL(fileURLWithPath: path), isConnected: FileManager.default.fileExists(atPath: path))
        }
        screen = .chooseLoad
    }

    var chosenLoadFolders: [URL] { sidebarFolders.flatMap(\.selectedFolders) }

    func scanChosenFolders() {
        let folders = chosenLoadFolders
        guard !folders.isEmpty else { return }
        loadedFolders = folders
        startScan(folders: folders, returnTo: .chooseLoad)
    }

    private func readList() -> PhotomatorList? {
        do {
            let loaded = try PhotomatorList(contentsOf: AppPaths.list)
            list = loaded
            return loaded
        } catch {
            message = "Photomator's ratings can't be read: \(error)"
            return nil
        }
    }

    // MARK: Scan

    private func startScan(folders: [URL], returnTo: Screen) {
        guard !folders.isEmpty else { return }
        scanned = 0
        screen = .working

        scanTask = Task {
            let work = Task.detached(priority: .userInitiated) { [weak self] in
                try PhotoScanner.scan(folders: folders) { count in
                    guard count % 25 == 0 else { return }
                    Task { @MainActor in self?.scanned = count }
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                self.scan = result
                self.folderRatings = SummaryTrees.ratings(in: result)
                self.writeSettings = WriteSettings()
                self.settings = ConflictSettings()
                self.screen = .summary
            } catch is CancellationError {
                self.screen = returnTo
            } catch {
                self.message = "\(error)"
                self.screen = returnTo
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: Summary

    private func recalculate() {
        guard let scan else {
            determination = nil
            undecidedWrites = nil
            return
        }
        let result = Determiner.determine(scan, settings: settings)
        undecidedWrites = result
        conflictFolders = SummaryTrees.conflicts(in: result, scan: scan)
        writeFolders = SummaryTrees.writes(in: result, scan: scan)
        applyWriteSettings()
        if flow == .load, let list {
            let decisions = result.decisions
            listChanges = ListWriter.plan(Self.forList(decisions), list: list).changes
            listUpdatedPhotos = ListText.photosToUpdate(decisions, list: list)
        }
    }

    private func applyWriteSettings() {
        guard let base = undecidedWrites else {
            determination = nil
            return
        }
        let writes = writeSettings
        determination = Determination(folders: base.folders.map { folder in
            FolderDecisions(folder: folder.folder, decisions: folder.decisions.map(writes.apply))
        })
        refreshWindow()
    }

    /// The list holds the final value, and a field no file holds counts as unrated: the file wins.
    private nonisolated static func forList(_ decisions: [PhotoDecision]) -> [PhotoDecision] {
        decisions.map { decision in
            var copy = PhotoDecision(
                photo: decision.photo, sources: decision.sources, conflict: decision.conflict,
                value: decision.valueForList, changesImage: decision.changesImage,
                changesSidecar: decision.changesSidecar, isSkipped: decision.isSkipped
            )
            copy.isIgnored = decision.isIgnored
            copy.isWriteSkipped = decision.isWriteSkipped
            return copy
        }
    }

    var action: (text: String, isEnabled: Bool) {
        guard let counts = determination?.counts else { return ("Nothing to change", false) }
        return flow == .load ? ActionText.load(counts, listChanges: listChanges) : ActionText.save(counts)
    }

    func conflicts(of type: ConflictType, in folders: Set<String>? = nil) -> [PhotoDecision] {
        (determination?.decisions ?? []).filter {
            $0.conflict == type && (folders == nil || folders!.contains($0.photo.folderPath))
        }
    }

    func showConflicts(_ type: ConflictType, in folders: Set<String>?) {
        windowConflict = type
        windowWrite = nil
        windowFolders = folders
        refreshWindow()
    }

    func showWrites(_ kind: WriteKind, in folders: Set<String>?) {
        windowWrite = kind
        windowConflict = nil
        windowFolders = folders
        refreshWindow()
    }

    /// The window's rows, kept up to date with the choices. Built once per change, not per page.
    private func refreshWindow() {
        let all = determination?.decisions ?? []
        let folders = windowFolders
        func inFolders(_ decision: PhotoDecision) -> Bool {
            folders == nil || folders!.contains(decision.photo.folderPath)
        }
        if let type = windowConflict {
            windowPhotos = all.filter { $0.conflict == type && inFolders($0) }
        } else if let kind = windowWrite {
            windowPhotos = all.filter { $0.writeKind == kind && inFolders($0) }
        } else {
            windowPhotos = []
        }
    }

    // MARK: Apply

    func apply() {
        withPhotomatorClosed { [self] in runApply() }
    }

    private func runApply() {
        guard let decisions = determination?.decisions else { return }
        let flow = flow
        applied = 0
        screen = .applying

        Task {
            let work = Task.detached(priority: .userInitiated) { [weak self] () throws -> (ListChanges?, WriteResult) in
                let written = try FileWriter.apply(decisions, backupFolder: AppPaths.backups) { count in
                    Task { @MainActor in self?.applied = count }
                }
                // The list comes last, and only once the files hold what it will say.
                guard flow == .load, written.failures.isEmpty else { return (nil, written) }
                let result = try ListWriter.apply(
                    Self.forList(decisions), to: AppPaths.list, backupFolder: AppPaths.backups
                )
                return (result.changes, written)
            }
            do {
                let (changes, written) = try await work.value
                finish(listChanges: changes, written: written)
            } catch {
                self.screen = .summary
                self.message = "Stopped: \(error)"
            }
        }
    }

    private func finish(listChanges: ListChanges?, written: WriteResult) {
        var lines: [String] = []
        if flow == .load, !loadedFolders.isEmpty {
            lines.append("Loaded: " + loadedFolders.map(\.lastPathComponent).joined(separator: ", "))
        }
        if written.imagesWritten + written.sidecarsWritten + written.sidecarsCreated > 0 {
            let toRaws = written.sidecarsWritten + written.sidecarsCreated
            lines.append("Copied: \(toRaws) ratings to RAWs, \(written.imagesWritten) to JPGs.")
        }
        if flow == .load, let listChanges, !listChanges.isEmpty {
            lines.append(ListText.updated(listUpdatedPhotos))
        } else if flow == .restore, let listChanges {
            lines.append(Self.describe(listChanges))
        }
        if !written.failures.isEmpty {
            lines.append("\(written.failures.count) files failed.")
            if flow == .load { lines.append("Photomator wasn't updated.") }
            failureLog = FailureLog.write(written.failures, to: AppPaths.backups)
        }
        resultLines = lines
        screen = .result
    }

    static func describe(_ changes: ListChanges) -> String {
        "Photomator: ratings \(changes.ratingsAdded) added, \(changes.ratingsChanged) changed, \(changes.ratingsRemoved) removed; "
            + "flags \(changes.flagsAdded) added, \(changes.flagsChanged) changed, \(changes.flagsRemoved) removed."
    }

    func showFailureLog() {
        if let failureLog { NSWorkspace.shared.activateFileViewerSelecting([failureLog]) }
    }

    // MARK: Restore

    func startRestore() {
        flow = .restore
        backups = ListBackup.all(in: AppPaths.backups)
        screen = .chooseRestore
    }

    func choose(_ backup: ListBackup) {
        do {
            let chosen = try PhotomatorList(contentsOf: backup.url)
            let current = try PhotomatorList(contentsOf: AppPaths.list)
            let comparison = RestoreComparison(chosen: chosen, current: current) {
                FileManager.default.fileExists(atPath: $0)
            }
            chosenBackup = backup
            restoreComparison = comparison
            restoreWritesPhotos = false
            scanned = 0
            screen = .working

            scanTask = Task {
                let found = await Task.detached(priority: .userInitiated) {
                    Restorer.conflicts(with: chosen, photoKeys: comparison.photosInList)
                }.value
                restoreConflicts = found
                screen = .restoreSummary
            }
        } catch {
            message = "This backup can't be read: \(error)"
        }
    }

    func applyRestore() {
        withPhotomatorClosed { [self] in runRestore() }
    }

    private func runRestore() {
        guard let backup = chosenBackup, let comparison = restoreComparison else { return }
        let decisions = restoreWritesPhotos ? restoreConflicts : []
        applied = 0
        screen = .applying

        Task {
            let work = Task.detached(priority: .userInitiated) { [weak self] () throws -> WriteResult in
                try ListWriter.restore(backup.url, to: AppPaths.list, backupFolder: AppPaths.backups)
                return try FileWriter.apply(decisions, backupFolder: AppPaths.backups) { count in
                    Task { @MainActor in self?.applied = count }
                }
            }
            do {
                finish(listChanges: comparison.changes, written: try await work.value)
            } catch {
                self.screen = .restoreSummary
                self.message = "Stopped: \(error)"
            }
        }
    }
}
