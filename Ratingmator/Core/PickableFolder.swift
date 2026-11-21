import Combine
import Foundation

/// A folder in the Load folder choice: a sidebar folder, or a subfolder of one (SPEC 4.3).
final class PickableFolder: ObservableObject, Identifiable {
    let url: URL
    let isConnected: Bool
    weak var parent: PickableFolder?

    @Published private(set) var isOn = false
    @Published private(set) var children: [PickableFolder]?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isConnected: Bool = true, parent: PickableFolder? = nil) {
        self.url = url
        self.isConnected = isConnected
        self.parent = parent
    }

    /// The subfolders, read the first time the folder is expanded.
    func loadChildren() {
        guard children == nil, isConnected else { return }
        let found = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        children = found
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { $0.pathExtension.isEmpty || $0.pathExtension != "photo-edit" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { PickableFolder(url: $0, parent: self) }
        children?.forEach { $0.isOn = isOn }
    }

    /// Ticking a folder ticks everything under it. Unticking a subfolder unticks the folders above
    /// it, whose other subfolders stay as they were.
    func set(on: Bool) {
        guard isConnected else { return }
        setDown(on)
        var ancestor = parent
        while let node = ancestor {
            node.isOn = node.children?.allSatisfy(\.isOn) ?? false
            ancestor = node.parent
        }
    }

    private func setDown(_ on: Bool) {
        isOn = on
        children?.forEach { $0.setDown(on) }
    }

    /// The folders to scan: a ticked folder stands for all that's under it.
    var selectedFolders: [URL] {
        if isOn { return [url] }
        return children?.flatMap(\.selectedFolders) ?? []
    }
}
