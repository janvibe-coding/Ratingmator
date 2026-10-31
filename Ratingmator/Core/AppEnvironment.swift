import AppKit
import Foundation

/// Where the app reads and writes. Debug builds use a test list and test backups, so a build made
/// during development can't reach the real list. Only a Release build uses the real locations.
nonisolated enum AppPaths {
    private static let home = URL(fileURLWithPath: NSHomeDirectory())

    #if DEBUG
    private static let root = home.appendingPathComponent("Ratingmator-debug")
    static let list = root.appendingPathComponent("FilesLibrary.plist")
    static let backups = root.appendingPathComponent("backups")
    #else
    static let list = home.appendingPathComponent(
        "Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Files Library/FilesLibrary.plist"
    )
    static let backups = home.appendingPathComponent("Library/Application Support/Ratingmator/backups")
    #endif
}

/// Quitting and opening Photomator (SPEC 7).
enum Photomator {
    static var isRunning: Bool { ListWriter.photomatorIsRunning() }

    /// Quits it normally, as ⌘Q does, and waits up to 30 seconds. Returns whether it's closed.
    static func quit() async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ListWriter.photomatorBundleID) {
            app.terminate()
        }
        for _ in 0..<60 {
            if !isRunning { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return !isRunning
    }

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ListWriter.photomatorBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Full Disk Access (SPEC 4.7). Debug builds touch nothing protected, so they don't need it.
nonisolated enum FullDiskAccess {
    static var isGranted: Bool {
        #if DEBUG
        return true
        #else
        // A folder macOS only opens with Full Disk Access. Nothing in it is read.
        let probe = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
        #endif
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The files that failed in a run, saved to the backup folder.
nonisolated enum FailureLog {
    static func write(_ failures: [WriteFailure], to folder: URL) -> URL? {
        guard !failures.isEmpty else { return nil }
        let text = failures.map { "\($0.file.path)\t\($0.reason)" }.joined(separator: "\n") + "\n"
        let file = folder.appendingPathComponent("failures-\(FileWriter.timestamp()).txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? text.write(to: file, atomically: true, encoding: .utf8)) == nil ? nil : file
    }
}
