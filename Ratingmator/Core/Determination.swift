import Foundation

nonisolated enum RatingDifference: Int, Hashable, Sendable {
    case rawOnly, rawHigher, jpgHigher

    var title: String {
        switch self {
        case .rawOnly: "RAW has a rating, JPG doesn't"
        case .rawHigher: "RAW has a higher rating than JPG"
        case .jpgHigher: "JPG has a higher rating than RAW"
        }
    }
}

nonisolated enum FlagDifference: Int, Hashable, Sendable {
    case rawPick, rawReject, jpgPickRawReject, jpgRejectRawPick

    var title: String {
        switch self {
        case .rawPick: "RAW has a pick, JPG doesn't"
        case .rawReject: "RAW has a reject, JPG doesn't"
        case .jpgPickRawReject: "JPG has a pick, RAW has a reject"
        case .jpgRejectRawPick: "JPG has a reject, RAW has a pick"
        }
    }
}

/// What differs between a pair's JPG and RAW (SPEC 5.2). Each different kind gets its own line.
nonisolated struct ConflictType: Hashable, Sendable {
    let rating: RatingDifference?
    let flag: FlagDifference?

    var title: String {
        [rating?.title, flag?.title].compactMap { $0 }.joined(separator: "; ")
    }

    /// Ratings first, then flags, then the two together.
    var sortKey: Int {
        switch (rating, flag) {
        case (let rating?, nil): rating.rawValue
        case (nil, let flag?): 10 + flag.rawValue
        case (let rating?, let flag?): 20 + rating.rawValue * 10 + flag.rawValue
        case (nil, nil): 100
        }
    }

    /// nil when the two files don't conflict. A RAW without a value never does: it takes the JPG's.
    init?(jpgStars: Int?, rawStars: Int?, jpgFlag: Int?, rawFlag: Int?) {
        let jpgStars = jpgStars ?? 0
        let rawStars = rawStars ?? 0
        let jpgFlag = jpgFlag ?? 0
        let rawFlag = rawFlag ?? 0

        var rating: RatingDifference?
        if rawStars != 0, jpgStars != rawStars {
            rating = jpgStars == 0 ? .rawOnly : rawStars > jpgStars ? .rawHigher : .jpgHigher
        }
        var flag: FlagDifference?
        if rawFlag != 0, jpgFlag != rawFlag {
            switch (jpgFlag, rawFlag) {
            case (0, 1): flag = .rawPick
            case (0, -1): flag = .rawReject
            case (1, -1): flag = .jpgPickRawReject
            default: flag = .jpgRejectRawPick
            }
        }
        guard rating != nil || flag != nil else { return nil }
        self.rating = rating
        self.flag = flag
    }
}

/// The choice for all photos of a conflict type. Ignore leaves those photos as they are.
nonisolated enum ConflictChoice: CaseIterable, Hashable, Sendable {
    case ignore, oneByOne, jpgWins, rawWins, highest, lowest
}

nonisolated enum ValueSource: Hashable, Sendable {
    case jpg, raw
}

/// The choice for one photo (SPEC 4.5).
nonisolated enum PhotoOverride: Equatable, Sendable {
    case source(ValueSource)
    case new(PhotoValue)
}

nonisolated struct ConflictSettings: Equatable, Sendable {
    private struct FolderKey: Hashable, Sendable {
        let type: ConflictType
        let folder: String
    }

    var choices: [ConflictType: ConflictChoice] = [:]
    var overrides: [String: PhotoOverride] = [:]
    private var folderChoices: [FolderKey: ConflictChoice] = [:]

    /// A folder's own choice, or else the choice for all folders.
    func choice(for type: ConflictType, folder: String) -> ConflictChoice {
        folderChoices[FolderKey(type: type, folder: folder)] ?? choices[type] ?? .ignore
    }

    /// The choice these folders share. nil when they differ.
    func overall(for type: ConflictType, folders: [String]) -> ConflictChoice? {
        let found = Set(folders.map { choice(for: type, folder: $0) })
        if found.isEmpty { return choices[type] ?? .ignore }
        return found.count == 1 ? found.first : nil
    }

    mutating func set(_ type: ConflictType, folder: String, to choice: ConflictChoice) {
        folderChoices[FolderKey(type: type, folder: folder)] = choice
    }

    mutating func set(_ type: ConflictType, folders: [String], to choice: ConflictChoice) {
        for folder in folders { set(type, folder: folder, to: choice) }
    }

    /// Sets every folder, replacing the choices made per folder.
    mutating func setAll(_ type: ConflictType, to choice: ConflictChoice) {
        choices[type] = choice
        folderChoices = folderChoices.filter { $0.key.type != type }
    }
}

/// How flags compare for highest and lowest: a pick, then a reject, then no flag. Any flag beats no flag.
nonisolated func flagRank(_ flag: Int) -> Int {
    switch flag {
    case 1: 2
    case -1: 1
    default: 0
    }
}

/// What the files of one photo hold. A file this photo doesn't have is left out.
nonisolated struct PhotoSources: Equatable, Sendable {
    var jpg: PhotoValue?
    var raw: PhotoValue?

    /// The source with the highest rating, where no rating counts as 0. A tie goes to the higher
    /// flag, where any flag beats no flag, then to the JPG.
    var preselected: ValueSource? {
        var best: (source: ValueSource, stars: Int, flag: Int)?
        for (source, value) in [(ValueSource.jpg, jpg), (.raw, raw)] {
            guard let value else { continue }
            let stars = value.stars ?? 0
            let flag = flagRank(value.flag?.rawValue ?? 0)
            if best == nil || stars > best!.stars || (stars == best!.stars && flag > best!.flag) {
                best = (source, stars, flag)
            }
        }
        return best?.source
    }
}

/// The outcome for one photo. Nothing is written here: this says what writing would do.
nonisolated struct PhotoDecision: Equatable, Sendable {
    let photo: Photo
    let sources: PhotoSources
    let conflict: ConflictType?
    /// The final value. nil for a field no file holds, or for an ignored conflict.
    let value: PhotoValue
    let changesImage: Bool
    let changesSidecar: Bool
    /// A file couldn't be read: the photo is left alone.
    let isSkipped: Bool
    /// A conflict set to ignore: the photo is left alone.
    var isIgnored = false

    var createsSidecar: Bool { changesSidecar && photo.sidecarURL == nil }
    var isLeftAlone: Bool { isSkipped || isIgnored }

    /// As the list should hold it: a field no file holds counts as unrated or unflagged, since the file wins.
    var valueForList: PhotoValue {
        PhotoValue(stars: value.stars ?? 0, flag: value.flag ?? Flag.none)
    }
}

/// The counts a summary shows for conflicts and writes.
nonisolated struct DecisionCounts: Equatable, Sendable {
    var conflicts: [ConflictType: Int] = [:]
    var ignored = 0
    var jpgsToRaws = 0
    var rawsToJpgs = 0
    var sidecarsToCreate = 0
    var skipped = 0

    var filesToChange: Int { jpgsToRaws + rawsToJpgs }

    init() {}

    init(_ decisions: [PhotoDecision]) {
        for decision in decisions {
            if let conflict = decision.conflict { conflicts[conflict, default: 0] += 1 }
            if decision.isIgnored { ignored += 1 }
            if decision.changesSidecar { jpgsToRaws += 1 }
            if decision.changesImage { rawsToJpgs += 1 }
            if decision.createsSidecar { sidecarsToCreate += 1 }
            if decision.isSkipped { skipped += 1 }
        }
    }
}

nonisolated struct FolderDecisions: Equatable, Sendable {
    let folder: URL
    let decisions: [PhotoDecision]

    var counts: DecisionCounts { DecisionCounts(decisions) }
}

nonisolated struct Determination: Equatable, Sendable {
    let folders: [FolderDecisions]

    var decisions: [PhotoDecision] { folders.flatMap(\.decisions) }
    var counts: DecisionCounts { DecisionCounts(decisions) }
}

/// Works out each photo's value, separately for stars and flag (SPEC 5).
nonisolated enum Determiner {
    static func determine(_ scan: ScanResult, settings: ConflictSettings = ConflictSettings()) -> Determination {
        Determination(folders: scan.folders.map { folder in
            FolderDecisions(folder: folder.folder, decisions: folder.photos.map { decide($0, settings: settings) })
        })
    }

    /// One photo with its value set outright, whatever its files hold.
    static func decide(_ item: ScannedPhoto, setting value: PhotoValue) -> PhotoDecision {
        decide(item, settings: ConflictSettings(), forced: value)
    }

    static func decide(
        _ item: ScannedPhoto, settings: ConflictSettings = ConflictSettings(), forced: PhotoValue? = nil
    ) -> PhotoDecision {
        let photo = item.photo
        guard item.image != .unreadable, item.sidecar != .unreadable else {
            return PhotoDecision(
                photo: photo, sources: PhotoSources(), conflict: nil, value: .empty,
                changesImage: false, changesSidecar: false, isSkipped: true
            )
        }

        let image = value(of: item.image)
        let sidecar = value(of: item.sidecar)
        let sources = PhotoSources(
            jpg: photo.imageURL == nil ? nil : image ?? .empty,
            raw: photo.rawURL == nil ? nil : sidecar ?? .empty
        )

        let conflict = photo.kind == .pair ? ConflictType(
            jpgStars: image?.stars, rawStars: sidecar?.stars,
            jpgFlag: image?.flag?.rawValue, rawFlag: sidecar?.flag?.rawValue
        ) : nil
        let starsDiffer = conflict?.rating != nil
        let flagsDiffer = conflict?.flag != nil

        var final: PhotoValue
        var isIgnored = false
        if let forced {
            final = forced
        } else if let conflict {
            var choice = settings.choice(for: conflict, folder: photo.folderPath)
            var handSet: PhotoValue?
            if choice == .oneByOne {
                switch settings.overrides[photo.listKey] ?? sources.preselected.map({ .source($0) }) {
                case .source(.jpg): choice = .jpgWins
                case .source(.raw): choice = .rawWins
                case .new(let value): handSet = value
                case nil: choice = .ignore
                }
            }
            if let handSet {
                final = PhotoValue(stars: handSet.stars ?? 0, flag: handSet.flag ?? Flag.none)
            } else if choice == .ignore {
                final = .empty
                isIgnored = true
            } else {
                final = PhotoValue(
                    stars: resolve(jpg: image?.stars, raw: sidecar?.stars, differ: starsDiffer, choice: choice, rank: { $0 }),
                    flag: resolve(
                        jpg: image?.flag?.rawValue, raw: sidecar?.flag?.rawValue, differ: flagsDiffer, choice: choice,
                        rank: flagRank
                    ).flatMap(Flag.init)
                )
            }
        } else {
            final = PhotoValue(stars: image?.stars ?? sidecar?.stars, flag: image?.flag ?? sidecar?.flag)
        }

        return PhotoDecision(
            photo: photo,
            sources: sources,
            conflict: conflict,
            value: final,
            changesImage: photo.imageURL != nil && differs(image, from: final),
            changesSidecar: photo.rawURL != nil && differs(sidecar, from: final),
            isSkipped: false,
            isIgnored: isIgnored
        )
    }

    private static func value(of read: SourceRead) -> PhotoValue? {
        if case .value(let value) = read { return value }
        return nil
    }

    /// One field: stars, or a flag as its number (pick 1, none 0, reject -1), compared by rank.
    private static func resolve(jpg: Int?, raw: Int?, differ: Bool, choice: ConflictChoice, rank: (Int) -> Int) -> Int? {
        guard differ, let raw else { return jpg ?? raw }
        let jpgValue = jpg ?? 0
        switch choice {
        case .jpgWins: return jpgValue
        case .rawWins: return raw
        case .highest: return rank(raw) > rank(jpgValue) ? raw : jpgValue
        case .lowest: return rank(raw) < rank(jpgValue) ? raw : jpgValue
        case .ignore, .oneByOne: return nil
        }
    }

    /// A file differs only where the final value says something else. No field and a final 0 or
    /// no flag mean the same, so such a file isn't rewritten and no sidecar is created for it.
    static func differs(_ file: PhotoValue?, from final: PhotoValue) -> Bool {
        if let stars = final.stars, (file?.stars ?? 0) != stars { return true }
        if let flag = final.flag, (file?.flag ?? Flag.none) != flag { return true }
        return false
    }
}

/// The table at the top of the summary: photos by type and rating. A pair counts by its JPG.
nonisolated struct RatingTable: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var photos = 0
        var stars = [Int](repeating: 0, count: 6)  // index 0 is no rating
        var picks = 0
        var rejects = 0

        mutating func add(_ value: PhotoValue?) {
            photos += 1
            stars[value?.stars ?? 0] += 1
            if value?.flag == .pick { picks += 1 }
            if value?.flag == .reject { rejects += 1 }
        }
    }

    var jpgOnly = Row()
    var rawOnly = Row()
    var pairs = Row()
    var unreadable = 0

    init(_ photos: [ScannedPhoto]) {
        for item in photos {
            if item.image == .unreadable || item.sidecar == .unreadable {
                unreadable += 1
                continue
            }
            switch item.photo.kind {
            case .embedded:
                jpgOnly.add(Self.value(of: item.image))
            case .rawOnly, .dng:
                rawOnly.add(Self.value(of: item.sidecar))
            case .pair:
                pairs.add(Self.value(of: item.image))
            }
        }
    }

    private static func value(of read: SourceRead) -> PhotoValue? {
        if case .value(let value) = read { return value }
        return nil
    }
}

/// A folder in the summary's tree, with what it and everything under it adds up to.
nonisolated struct FolderNode<Value: Equatable & Sendable>: Equatable, Identifiable, Sendable {
    let path: String
    let name: String
    let value: Value
    let children: [FolderNode<Value>]
    /// The folders at or under this one that directly hold photos. A choice here applies to these.
    let paths: [String]

    var id: String { path }
}

nonisolated enum FolderTree {
    private final class Builder<Value> {
        let path: String
        let name: String
        var own: Value?
        var children: [String: Builder<Value>] = [:]

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    /// One top node per scanned folder, and under it the subfolders that lead to an entry.
    static func build<Value>(
        _ entries: [String: Value], roots: [URL], zero: Value, add: (Value, Value) -> Value
    ) -> [FolderNode<Value>] {
        var tops: [String: Builder<Value>] = [:]
        for (path, value) in entries {
            let root = roots.map(\.path).first { path == $0 || path.hasPrefix($0 + "/") }
                ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
            var node = tops[root] ?? Builder<Value>(path: root, name: URL(fileURLWithPath: root).lastPathComponent)
            tops[root] = node
            var current = root
            for part in path.dropFirst(root.count).split(separator: "/").map(String.init) {
                current += "/" + part
                let next = node.children[part] ?? Builder<Value>(path: current, name: part)
                node.children[part] = next
                node = next
            }
            node.own = value
        }
        return sorted(tops.values.map { finish($0, zero: zero, add: add) })
    }

    private static func finish<Value>(
        _ builder: Builder<Value>, zero: Value, add: (Value, Value) -> Value
    ) -> FolderNode<Value> {
        let children = sorted(builder.children.values.map { finish($0, zero: zero, add: add) })
        var total = builder.own ?? zero
        for child in children { total = add(total, child.value) }
        return FolderNode(
            path: builder.path,
            name: builder.name,
            value: total,
            children: children,
            paths: (builder.own == nil ? [] : [builder.path]) + children.flatMap(\.paths)
        )
    }

    private static func sorted<Value>(_ nodes: [FolderNode<Value>]) -> [FolderNode<Value>] {
        nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension RatingTable.Row {
    nonisolated static func + (first: RatingTable.Row, second: RatingTable.Row) -> RatingTable.Row {
        var total = RatingTable.Row()
        total.photos = first.photos + second.photos
        total.stars = zip(first.stars, second.stars).map { $0 + $1 }
        total.picks = first.picks + second.picks
        total.rejects = first.rejects + second.rejects
        return total
    }
}

nonisolated enum SummaryTrees {
    /// Photos by rating per folder: all types together, with a pair counting by its JPG.
    static func ratings(in scan: ScanResult) -> [FolderNode<RatingTable.Row>] {
        var rows: [String: RatingTable.Row] = [:]
        for item in scan.folders.flatMap(\.photos) {
            guard item.image != .unreadable, item.sidecar != .unreadable else { continue }
            let read = item.photo.imageURL != nil ? item.image : item.sidecar
            var value: PhotoValue?
            if case .value(let found) = read { value = found }
            rows[item.photo.folderPath, default: RatingTable.Row()].add(value)
        }
        return FolderTree.build(rows, roots: scan.folders.map(\.folder), zero: RatingTable.Row(), add: +)
    }

    /// For each kind of conflict, the folders that have it, with their counts.
    static func conflicts(in determination: Determination, scan: ScanResult) -> [ConflictType: [FolderNode<Int>]] {
        var counts: [ConflictType: [String: Int]] = [:]
        for decision in determination.decisions {
            guard let conflict = decision.conflict else { continue }
            counts[conflict, default: [:]][decision.photo.folderPath, default: 0] += 1
        }
        return counts.mapValues { FolderTree.build($0, roots: scan.folders.map(\.folder), zero: 0, add: +) }
    }
}

/// The action button says what it will do.
nonisolated enum ActionText {
    private static func copies(_ counts: DecisionCounts) -> String? {
        var parts: [String] = []
        if counts.jpgsToRaws > 0 {
            parts.append(counts.jpgsToRaws == 1
                ? "Copy rating of 1 JPG to its RAW" : "Copy rating of \(counts.jpgsToRaws.formatted()) JPGs to their RAW")
        }
        if counts.rawsToJpgs > 0 {
            let phrase = counts.rawsToJpgs == 1 ? "1 RAW to its JPG" : "\(counts.rawsToJpgs.formatted()) RAWs to their JPG"
            parts.append(parts.isEmpty ? "Copy rating of \(phrase)" : "of \(phrase)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", and ")
    }

    static func save(_ counts: DecisionCounts) -> (text: String, isEnabled: Bool) {
        guard let copies = copies(counts) else { return ("Nothing to change", false) }
        return (copies, true)
    }

    /// An ignored conflict doesn't stop Load: that photo is left out, and the summary warns about it.
    static func load(_ counts: DecisionCounts, listChanges: ListChanges) -> (text: String, isEnabled: Bool) {
        switch (copies(counts), listChanges.isEmpty) {
        case (let copies?, false): return (copies + ", then update Photomator", true)
        case (let copies?, true): return (copies, true)
        case (nil, false): return ("Update Photomator", true)
        case (nil, true): return ("Nothing to change", false)
        }
    }
}

/// What Load tells about the list: how many photos get a new value in it.
nonisolated enum ListText {
    static func photosToUpdate(_ decisions: [PhotoDecision], list: PhotomatorList) -> Int {
        decisions.filter { decision in
            guard !decision.isLeftAlone else { return false }
            let listValue = list.value(forKey: decision.photo.listKey)
            let photos = decision.valueForList
            return (listValue.stars ?? 0) != photos.stars || (listValue.flag ?? Flag.none) != photos.flag
        }.count
    }

    static func ignoredWarning(_ count: Int) -> String {
        count == 1
            ? "1 photo with a conflict will not be updated in Photomator."
            : "\(count.formatted()) photos with a conflict will not be updated in Photomator."
    }

    static func willUpdate(_ count: Int) -> String {
        count == 1
            ? "The value of 1 photo will be updated in Photomator."
            : "The value of \(count.formatted()) photos will be updated in Photomator."
    }

    static func updated(_ count: Int) -> String {
        count == 1
            ? "The value of 1 photo was updated in Photomator."
            : "The value of \(count.formatted()) photos was updated in Photomator."
    }
}
