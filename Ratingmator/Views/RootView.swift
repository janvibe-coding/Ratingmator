import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .noAccess: NoAccessView()
            case .photomatorOpen: PhotomatorOpenView()
            case .start: StartView()
            case .chooseSave: ChooseSaveView()
            case .working: WorkingView()
            case .summary: SummaryView()
            case .applying: ApplyingView()
            case .result: ResultView()
            case .chooseRestore: ChooseRestoreView()
            case .restoreSummary: RestoreSummaryView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.launchCheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.screen == .noAccess || model.screen == .photomatorOpen || model.screen == .start {
                model.launchCheck()
            }
        }
        .alert(
            model.message ?? "",
            isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct NoAccessView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Ratingmator needs Full Disk Access.")
                .font(.title2)
            Text("System Settings → Privacy & Security → Full Disk Access")
            Button("Open System Settings") { FullDiskAccess.openSettings() }
        }
        .padding(32)
    }
}

struct PhotomatorOpenView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Photomator is open.")
                .font(.title2)
            if model.isQuittingPhotomator {
                ProgressView()
            } else {
                Button("Quit Photomator") { model.quitPhotomator() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
    }
}

struct StartView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            startButton(
                "Save ratings to photos",
                detail: "Gives the JPG and RAW of each photo the same rating.",
                action: model.startSave
            )
            startButton(
                "Load ratings into Photomator",
                detail: "Does the same, then updates Photomator.",
                action: model.startLoad
            )
            Button("Restore earlier Photomator ratings") { model.startRestore() }
                .controlSize(.small)
                .disabled(!model.hasBackups)
        }
        .padding(32)
    }

    private func startButton(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Text(title)
                    .font(.title2)
                    .frame(width: 340, height: 52)
            }
            Text(detail)
                .foregroundColor(.secondary)
        }
    }
}

struct ChooseSaveView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            List {
                ForEach(model.droppedFolders, id: \.self) { folder in
                    Text(folder.path)
                }
                .onDelete { model.droppedFolders.remove(atOffsets: $0) }
                if model.droppedFolders.isEmpty {
                    Text("Drop folders here")
                        .foregroundColor(.secondary)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.addDropped(urls)
                return true
            }

            HStack {
                Button("Back") { model.backToStart() }
                Spacer()
                Button("Scan") { model.scanDroppedFolders() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.droppedFolders.isEmpty)
            }
        }
        .padding(20)
    }
}

struct WorkingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            if model.flow != .restore {
                Text("\(model.scanned) photos")
                    .monospacedDigit()
                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
    }
}

struct ApplyingView: View {
    @EnvironmentObject private var model: AppModel

    private var total: Int { model.determination?.counts.filesToChange ?? 0 }

    var body: some View {
        VStack(spacing: 16) {
            if model.flow != .restore, total > 0 {
                ProgressView(value: Double(min(model.applied, total)), total: Double(total))
                    .frame(width: 320)
            } else {
                ProgressView()
            }
            Text("\(model.applied) files")
                .monospacedDigit()
        }
        .padding(32)
    }
}

struct ResultView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            ForEach(model.resultLines, id: \.self) { line in
                Text(line)
            }
            if model.failureLog != nil {
                Button("Show failed files") { model.showFailureLog() }
            }
            HStack {
                if model.flow == .save {
                    Button("Done") { model.backToStart() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Quit") { model.quitApp() }
                    Button("Open Photomator") { model.openPhotomatorAndQuit() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
    }
}

struct ChooseRestoreView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            List(model.backups) { backup in
                Button {
                    model.choose(backup)
                } label: {
                    HStack {
                        Text(backup.date.formatted(date: .abbreviated, time: .standard))
                        Spacer()
                        Text("\(backup.ratings) ratings, \(backup.flags) flags")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Back") { model.backToStart() }
        }
        .padding(20)
    }
}

struct RestoreSummaryView: View {
    @EnvironmentObject private var model: AppModel

    private var photoWrites: Int { model.restoreConflicts.count }

    private var actionText: String {
        guard model.restoreWritesPhotos, photoWrites > 0 else { return "Restore Photomator" }
        return photoWrites == 1
            ? "Restore Photomator, and write these ratings to 1 photo"
            : "Restore Photomator, and write these ratings to \(photoWrites) photos"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let comparison = model.restoreComparison {
                Text(AppModel.describe(comparison.changes))
                Text("Sidebar folders: \(comparison.sidebarFoldersAdded.count) added, \(comparison.sidebarFoldersRemoved.count) removed.")
                Text("No longer on this Mac: \(comparison.missingPhotos) \(comparison.missingPhotos == 1 ? "photo" : "photos"), \(comparison.missingFolders.count) \(comparison.missingFolders.count == 1 ? "folder" : "folders").")
                    .foregroundColor(comparison.missingPhotos + comparison.missingFolders.count > 0 ? .orange : .primary)

                if !model.restoreConflicts.isEmpty {
                    Divider()
                    HStack {
                        Text("\(photoWrites)").bold().monospacedDigit()
                        Text("Photos hold a different rating or flag than these ratings")
                        Spacer()
                        Picker("", selection: $model.restoreWritesPhotos) {
                            Text("Ignore").tag(false)
                            Text("Use these ratings").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }

                Spacer()
                HStack {
                    Button("Cancel") { model.backToStart() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if model.isQuittingPhotomator { ProgressView().controlSize(.small) }
                    Button(actionText) { model.applyRestore() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isQuittingPhotomator)
                }
            }
        }
        .padding(20)
    }
}

enum ValueText {
    static func describe(_ value: PhotoValue) -> String {
        let stars = (value.stars ?? 0) == 0 ? "no rating" : "\(value.stars ?? 0) ★"
        switch value.flag {
        case .pick: return stars + ", pick"
        case .reject: return stars + ", reject"
        case .none?, nil: return stars
        }
    }
}
