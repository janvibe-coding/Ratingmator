import AppKit
import ImageIO
import SwiftUI

/// The photos of one conflict type, a page at a time (SPEC 4.5). Choices are kept in the summary.
/// A page holds as many rows as fit the window, so there's nothing to scroll past.
struct ConflictsWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var first = 0

    private let rowHeight: CGFloat = 84

    private var photos: [PhotoDecision] {
        model.windowConflict.map { model.conflicts(of: $0, in: model.windowFolders) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(photos.count) \(photos.count == 1 ? "photo" : "photos"): \(model.windowConflict?.title ?? "")")
                .bold()
            GeometryReader { geometry in
                let pageSize = max(1, Int(geometry.size.height / rowHeight))
                let start = min(first, max(0, photos.count - 1))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(photos.dropFirst(start).prefix(pageSize), id: \.photo.listKey) { decision in
                        ConflictRow(decision: decision)
                            .frame(height: rowHeight - 1, alignment: .leading)
                        Divider()
                    }
                    Spacer(minLength: 0)
                }
                .preference(key: PageSizeKey.self, value: pageSize)
            }
            .onPreferenceChange(PageSizeKey.self) { pageSize = $0 }

            HStack {
                Button("Previous") { first = max(0, first - pageSize) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(first == 0)
                Text("\(page) of \(pageCount)")
                    .monospacedDigit()
                Button("Next") { first += pageSize }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(first + pageSize >= photos.count)
                Spacer()
                Button("Close") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
        .onChange(of: model.windowConflict) { _ in first = 0 }
        .onChange(of: model.windowFolders) { _ in first = 0 }
    }

    @State private var pageSize = 1

    private var page: Int { first / max(1, pageSize) + 1 }
    private var pageCount: Int { max(1, (photos.count + pageSize - 1) / max(1, pageSize)) }
}

private struct PageSizeKey: PreferenceKey {
    static let defaultValue = 1

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = nextValue()
    }
}

/// One conflict: the photo's name and what its JPG and RAW hold, with the choice for it.
struct ConflictRow: View {
    @EnvironmentObject private var model: AppModel
    let decision: PhotoDecision

    private var key: String { decision.photo.listKey }

    private enum Option: Hashable { case jpg, raw, new }

    private var selected: PhotoOverride {
        if let chosen = model.settings.overrides[key] { return chosen }
        return decision.sources.preselected.map { .source($0) } ?? .new(PhotoValue(stars: 0, flag: Flag.none))
    }

    private var option: Binding<Option> {
        Binding {
            switch selected {
            case .source(.jpg): .jpg
            case .source(.raw): .raw
            case .new: .new
            }
        } set: { new in
            switch new {
            case .jpg: model.settings.overrides[key] = .source(.jpg)
            case .raw: model.settings.overrides[key] = .source(.raw)
            case .new: model.settings.overrides[key] = .new(newValue)
            }
        }
    }

    private var newValue: PhotoValue {
        if case .new(let value) = selected { return value }
        return PhotoValue(stars: decision.value.stars ?? 0, flag: decision.value.flag ?? Flag.none)
    }

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(url: decision.photo.imageURL ?? decision.photo.rawURL)
                .frame(width: 96, height: 72)
            Text(URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent)
                .frame(width: 180, alignment: .leading)
            Text("JPG: \(ValueText.describe(decision.sources.jpg ?? .empty))")
                .frame(width: 150, alignment: .leading)
            Text("RAW: \(ValueText.describe(decision.sources.raw ?? .empty))")
                .frame(width: 150, alignment: .leading)

            Picker("", selection: option) {
                Text("JPG").tag(Option.jpg)
                Text("RAW").tag(Option.raw)
                Text("New").tag(Option.new)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            if option.wrappedValue == .new {
                Picker("", selection: Binding(
                    get: { newValue.stars ?? 0 },
                    set: { model.settings.overrides[key] = .new(PhotoValue(stars: $0, flag: newValue.flag ?? Flag.none)) }
                )) {
                    ForEach(0...5, id: \.self) { Text("\($0) ★").tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)

                Picker("", selection: Binding(
                    get: { newValue.flag ?? Flag.none },
                    set: { model.settings.overrides[key] = .new(PhotoValue(stars: newValue.stars ?? 0, flag: $0)) }
                )) {
                    Text("Pick").tag(Flag.pick)
                    Text("Reject").tag(Flag.reject)
                    Text("No flag").tag(Flag.none)
                }
                .labelsHidden()
                .frame(width: 90)
            }
        }
        .monospacedDigit()
    }
}

/// The JPG, or the RAW's embedded preview when there's no JPG. Read through ImageIO; never written.
private struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let loaded = await Task.detached(priority: .utility) { Self.load(url) }.value
            image = loaded.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private nonisolated static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
