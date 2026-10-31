import AppKit
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let scan = model.scan {
                        RatingTableView(table: RatingTable(scan.folders.flatMap(\.photos)))
                        if !model.folderRatings.isEmpty {
                            DisclosureGroup("Per folder") {
                                FolderRatingsView(folders: model.folderRatings)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    ConflictsView()
                    if model.flow == .load {
                        ListSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
            }
            HStack {
                Button("Cancel") { model.backToStart() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isQuittingPhotomator { ProgressView().controlSize(.small) }
                Button(model.action.text) { model.apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.action.isEnabled || model.isQuittingPhotomator)
            }
        }
        .padding(20)
    }
}

/// Photos by type and rating. A pair counts by its JPG.
private struct RatingTableView: View {
    let table: RatingTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RatingHeader()
            Divider()
            RatingRow(name: "JPG only", row: table.jpgOnly)
            RatingRow(name: "RAW only", row: table.rawOnly)
            RatingRow(name: "RAW + JPG", row: table.pairs)
        }
        .monospacedDigit()

        if table.unreadable > 0 {
            Text("\(table.unreadable) photos can't be read and are left alone.")
                .foregroundColor(.orange)
        }
    }
}

/// Every other row is shaded, so a row's name and its values on the far right stay together.
private struct RowShade: ViewModifier {
    /// The stripe macOS uses in its own lists: light, and right in dark mode too.
    private static let stripe = NSColor.alternatingContentBackgroundColors.last ?? .clear

    let index: Int

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(index.isMultiple(of: 2) ? Color(nsColor: Self.stripe) : Color.clear)
    }
}

/// A list of folders as a tree: the top level first, and each folder expands one level deeper.
private struct TreeRows<Value: Equatable & Sendable> {
    let nodes: [FolderNode<Value>]
    let expanded: Set<String>

    var visible: [(node: FolderNode<Value>, depth: Int)] {
        func walk(_ nodes: [FolderNode<Value>], _ depth: Int) -> [(node: FolderNode<Value>, depth: Int)] {
            nodes.flatMap { node in
                [(node, depth)] + (expanded.contains(node.path) ? walk(node.children, depth + 1) : [])
            }
        }
        return walk(nodes, 0)
    }
}

/// A folder's name with its indent, and an arrow if it has subfolders.
private struct TreeName: View {
    let name: String
    let depth: Int
    let hasChildren: Bool
    let path: String
    @Binding var expanded: Set<String>

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
            } label: {
                Image(systemName: expanded.contains(path) ? "chevron.down" : "chevron.right")
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }
}

/// The ratings per folder, as a tree with the same columns as the table above it.
private struct FolderRatingsView: View {
    let folders: [FolderNode<RatingTable.Row>]
    @State private var expanded: Set<String> = []

    private var rows: [(node: FolderNode<RatingTable.Row>, depth: Int)] {
        TreeRows(nodes: folders, expanded: expanded).visible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RatingHeader()
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.node.path) { index, item in
                HStack(spacing: 0) {
                    TreeName(
                        name: item.node.name, depth: item.depth, hasChildren: !item.node.children.isEmpty,
                        path: item.node.path, expanded: $expanded
                    )
                    Spacer(minLength: 8)
                    RatingCells(row: item.node.value)
                }
                .modifier(RowShade(index: index))
            }
        }
        .monospacedDigit()
    }
}

private let ratingColumnWidth: CGFloat = 62

private struct RatingHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 8)
            Group {
                Text("Photos")
                Text("No rating")
                ForEach(1...5, id: \.self) { Text("\($0) ★") }
                Text("Pick")
                Text("Reject")
            }
            .frame(width: ratingColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .foregroundColor(.secondary)
    }
}

private struct RatingRow: View {
    let name: String
    let row: RatingTable.Row

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
            Spacer(minLength: 8)
            RatingCells(row: row)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
    }
}

private struct RatingCells: View {
    let row: RatingTable.Row

    var body: some View {
        Group {
            Text("\(row.photos)")
            ForEach(0...5, id: \.self) { Text("\(row.stars[$0])") }
            Text("\(row.picks)")
            Text("\(row.rejects)")
        }
        .frame(width: ratingColumnWidth, alignment: .trailing)
    }
}

private struct ConflictsView: View {
    @EnvironmentObject private var model: AppModel

    private var counts: [ConflictType: Int] { model.determination?.counts.conflicts ?? [:] }
    private var types: [ConflictType] { counts.keys.sorted { $0.sortKey < $1.sortKey } }

    var body: some View {
        if !counts.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                ForEach(types, id: \.self) { type in
                    ConflictSection(type: type, count: counts[type] ?? 0)
                }
            }
        }
    }
}

/// The choices a conflict can get, for all its folders or for one.
private struct ChoiceOptions: View {
    var body: some View {
        Text("Ignore").tag(ConflictChoice?.some(.ignore))
        Text("Decide one by one").tag(ConflictChoice?.some(.oneByOne))
        Text("Pick rating of JPG file").tag(ConflictChoice?.some(.jpgWins))
        Text("Pick rating of RAW file").tag(ConflictChoice?.some(.rawWins))
        Text("Pick highest rating").tag(ConflictChoice?.some(.highest))
        Text("Pick lowest rating").tag(ConflictChoice?.some(.lowest))
    }
}

private struct ConflictSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isExpanded = false
    @State private var expanded: Set<String> = []
    let type: ConflictType
    let count: Int

    private var folders: [FolderNode<Int>] { model.conflictFolders[type] ?? [] }
    private var allPaths: [String] { folders.flatMap(\.paths) }

    private func openPhotos(in folders: Set<String>?) {
        model.windowConflict = type
        model.windowFolders = folders
        openWindow(id: "conflicts")
    }

    /// nil when the folders have different choices. Picking a value sets every folder again.
    private var overall: Binding<ConflictChoice?> {
        Binding(
            get: { model.settings.overall(for: type, folders: allPaths) },
            set: {
                guard let choice = $0 else { return }
                model.settings.setAll(type, to: choice)
                if choice == .oneByOne { openPhotos(in: nil) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(count)").bold().monospacedDigit()
                Text(type.title)
                Spacer()
                if overall.wrappedValue == .oneByOne {
                    Button("Open") { openPhotos(in: nil) }
                        .foregroundColor(.primary)
                }
                Picker("", selection: overall) {
                    if overall.wrappedValue == nil {
                        Text("Mixed").tag(ConflictChoice?.none)
                    }
                    ChoiceOptions()
                }
                .labelsHidden()
                .frame(width: 200)
                .foregroundColor(.primary)
            }
            .foregroundColor(.red)

            DisclosureGroup("Per folder", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    let rows = TreeRows(nodes: folders, expanded: expanded).visible
                    ForEach(Array(rows.enumerated()), id: \.element.node.path) { index, item in
                        ConflictFolderRow(
                            type: type, node: item.node, depth: item.depth, expanded: $expanded,
                            open: { openPhotos(in: Set(item.node.paths)) }
                        )
                        .modifier(RowShade(index: index))
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

/// One folder under a conflict line. Its choice applies to everything under it.
private struct ConflictFolderRow: View {
    @EnvironmentObject private var model: AppModel
    let type: ConflictType
    let node: FolderNode<Int>
    let depth: Int
    @Binding var expanded: Set<String>
    let open: () -> Void

    private var choice: Binding<ConflictChoice?> {
        Binding(
            get: { model.settings.overall(for: type, folders: node.paths) },
            set: {
                guard let choice = $0 else { return }
                model.settings.set(type, folders: node.paths, to: choice)
                if choice == .oneByOne { open() }
            }
        )
    }

    var body: some View {
        HStack {
            TreeName(
                name: node.name, depth: depth, hasChildren: !node.children.isEmpty,
                path: node.path, expanded: $expanded
            )
            Text("\(node.value)").bold().monospacedDigit()
            Spacer()
            if choice.wrappedValue == .oneByOne {
                Button("Open", action: open)
            }
            Picker("", selection: choice) {
                if choice.wrappedValue == nil {
                    Text("Mixed").tag(ConflictChoice?.none)
                }
                ChoiceOptions()
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}

/// What Load will do in Photomator, and what it leaves out.
private struct ListSection: View {
    @EnvironmentObject private var model: AppModel

    private var ignored: Int { model.determination?.counts.ignored ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if ignored > 0 {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                    Text(ListText.ignoredWarning(ignored))
                        .font(.title3)
                        .bold()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.white)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red)
                .cornerRadius(8)
            }
            if model.listUpdatedPhotos > 0 {
                Text(ListText.willUpdate(model.listUpdatedPhotos))
            }
        }
    }
}
