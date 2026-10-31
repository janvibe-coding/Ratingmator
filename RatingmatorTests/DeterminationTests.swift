import Foundation
import Testing
@testable import Ratingmator

private let folder = URL(fileURLWithPath: "/photos")

private func pair(jpg: PhotoValue = .empty, sidecar: PhotoValue? = nil) -> ScannedPhoto {
    ScannedPhoto(
        photo: Photo(
            kind: .pair,
            imageURL: folder.appendingPathComponent("a.JPG"),
            rawURL: folder.appendingPathComponent("a.RAF"),
            sidecarURL: sidecar == nil ? nil : folder.appendingPathComponent("a.xmp")
        ),
        image: .value(jpg),
        sidecar: sidecar.map { .value($0) } ?? .absent
    )
}

private func jpgOnly(_ value: PhotoValue = .empty) -> ScannedPhoto {
    ScannedPhoto(
        photo: Photo(kind: .embedded, imageURL: folder.appendingPathComponent("a.JPG"), rawURL: nil, sidecarURL: nil),
        image: .value(value),
        sidecar: .absent
    )
}

private func rawOnly(sidecar: PhotoValue? = nil, kind: Photo.Kind = .rawOnly) -> ScannedPhoto {
    ScannedPhoto(
        photo: Photo(
            kind: kind,
            imageURL: nil,
            rawURL: folder.appendingPathComponent("a.RAF"),
            sidecarURL: sidecar == nil ? nil : folder.appendingPathComponent("a.xmp")
        ),
        image: .absent,
        sidecar: sidecar.map { .value($0) } ?? .absent
    )
}

private func stars(_ stars: Int) -> PhotoValue { PhotoValue(stars: stars, flag: nil) }
private func flag(_ flag: Flag) -> PhotoValue { PhotoValue(stars: nil, flag: flag) }

private let ratingConflict = ConflictType(jpgStars: 1, rawStars: 4, jpgFlag: nil, rawFlag: nil)!
private let flagConflict = ConflictType(jpgStars: nil, rawStars: nil, jpgFlag: 1, rawFlag: -1)!

private func settings(_ type: ConflictType, _ choice: ConflictChoice) -> ConflictSettings {
    var settings = ConflictSettings()
    settings.choices[type] = choice
    return settings
}

/// The choice applied to this photo's own kind of conflict.
private func decide(_ item: ScannedPhoto, _ choice: ConflictChoice) -> PhotoDecision {
    Determiner.decide(item, settings: settings(Determiner.decide(item).conflict!, choice))
}

struct NoConflictTests {
    @Test func aJPGAndRAWThatAgreeNeedNothing() {
        let value = PhotoValue(stars: 3, flag: .pick)
        let decision = Determiner.decide(pair(jpg: value, sidecar: value))
        #expect(decision.conflict == nil)
        #expect(decision.value == value)
        #expect(!decision.changesImage)
        #expect(!decision.changesSidecar)
    }

    @Test(arguments: [Photo.Kind.rawOnly, .dng])
    func aRAWOrDNGOnlyReadsItsSidecar(kind: Photo.Kind) {
        let decision = Determiner.decide(rawOnly(sidecar: stars(4), kind: kind))
        #expect(decision.conflict == nil)
        #expect(decision.value.stars == 4)
    }

    @Test func aJPGOnlyReadsItself() {
        let decision = Determiner.decide(jpgOnly(stars(2)))
        #expect(decision.conflict == nil)
        #expect(decision.value.stars == 2)
    }

    /// Raws without a rating take the JPG's, as that's how Photomator works.
    @Test(arguments: [nil, PhotoValue.empty, PhotoValue(stars: 0, flag: Flag.none)])
    func aRAWWithoutAValueTakesTheJPGs(sidecar: PhotoValue?) {
        let value = PhotoValue(stars: 3, flag: .pick)
        let decision = Determiner.decide(pair(jpg: value, sidecar: sidecar))
        #expect(decision.conflict == nil)
        #expect(decision.value == value)
        #expect(!decision.changesImage)
        #expect(decision.changesSidecar)
    }

    @Test func nothingAnywhereChangesNothing() {
        let decision = Determiner.decide(pair(sidecar: .empty))
        #expect(decision.conflict == nil)
        #expect(!decision.changesImage)
        #expect(!decision.changesSidecar)
    }

    @Test func aJPGRatedZeroAndARAWWithZeroCreateNothing() {
        let decision = Determiner.decide(pair(jpg: stars(0)))
        #expect(!decision.changesSidecar)
        #expect(!decision.createsSidecar)
    }
}

struct ConflictKindTests {
    private func kind(_ item: ScannedPhoto) -> ConflictType? { Determiner.decide(item).conflict }

    @Test func ratingsSplitByWhichSideHasWhat() {
        #expect(kind(pair(jpg: stars(0), sidecar: stars(2)))?.rating == .rawOnly)
        #expect(kind(pair(sidecar: stars(2)))?.rating == .rawOnly)
        #expect(kind(pair(jpg: stars(1), sidecar: stars(4)))?.rating == .rawHigher)
        #expect(kind(pair(jpg: stars(4), sidecar: stars(1)))?.rating == .jpgHigher)
    }

    @Test func flagsSplitByWhichSideHasWhat() {
        #expect(kind(pair(sidecar: flag(.pick)))?.flag == .rawPick)
        #expect(kind(pair(sidecar: flag(.reject)))?.flag == .rawReject)
        #expect(kind(pair(jpg: flag(.pick), sidecar: flag(.reject)))?.flag == .jpgPickRawReject)
        #expect(kind(pair(jpg: flag(.reject), sidecar: flag(.pick)))?.flag == .jpgRejectRawPick)
    }

    @Test func aPhotoWithBothHasOneKindWithBothParts() {
        let found = kind(pair(jpg: stars(1), sidecar: PhotoValue(stars: 4, flag: .pick)))
        #expect(found?.rating == .rawHigher)
        #expect(found?.flag == .rawPick)
        #expect(found?.title == "RAW has a higher rating than JPG; RAW has a pick, JPG doesn't")
    }

    @Test func differentKindsCountSeparately() {
        let counts = DecisionCounts([
            Determiner.decide(pair(sidecar: flag(.pick))),
            Determiner.decide(pair(sidecar: flag(.pick))),
            Determiner.decide(pair(sidecar: flag(.reject))),
        ])
        #expect(counts.conflicts.count == 2)
        #expect(counts.conflicts[ConflictType(jpgStars: nil, rawStars: nil, jpgFlag: nil, rawFlag: 1)!] == 2)
    }

    @Test func ratingKindsComeBeforeFlagKinds() {
        #expect(ratingConflict.sortKey < flagConflict.sortKey)
    }

    @Test func aRAWOnlyIsNeverAConflict() {
        #expect(Determiner.decide(rawOnly(sidecar: stars(2))).conflict == nil)
    }

    @Test func ignoreIsTheDefaultAndLeavesThePhotoAlone() {
        let decision = Determiner.decide(pair(jpg: stars(1), sidecar: stars(4)))
        #expect(decision.isIgnored)
        #expect(decision.isLeftAlone)
        #expect(!decision.changesImage)
        #expect(!decision.changesSidecar)
    }

    @Test(arguments: [
        (ConflictChoice.jpgWins, 1),
        (.rawWins, 4),
        (.highest, 4),
        (.lowest, 1),
    ])
    func eachChoiceOnARating(choice: ConflictChoice, expected: Int) {
        let decision = decide(pair(jpg: stars(1), sidecar: stars(4)), choice)
        #expect(decision.value.stars == expected)
        #expect(!decision.isIgnored)
        #expect(decision.changesImage == (expected != 1))
        #expect(decision.changesSidecar == (expected != 4))
    }

    @Test(arguments: [
        (ConflictChoice.highest, Flag.pick),
        (.lowest, .reject),
    ])
    func flagsRankPickAboveReject(choice: ConflictChoice, expected: Flag) {
        #expect(decide(pair(jpg: flag(.pick), sidecar: flag(.reject)), choice).value.flag == expected)
    }

    /// A flag beats no flag, a reject included.
    @Test(arguments: [Flag.pick, .reject])
    func highestKeepsAFlagOverNoFlag(flagged: Flag) {
        #expect(decide(pair(jpg: stars(0), sidecar: flag(flagged)), .highest).value.flag == flagged)
        let lowest = decide(pair(jpg: stars(0), sidecar: flag(flagged)), .lowest)
        #expect(lowest.value.flag == nil || lowest.value.flag == Flag.none)
    }

    /// RAW wins only where the RAW holds a value: a flag conflict doesn't wipe the JPG's rating.
    @Test func aChoiceOnlyDecidesTheFieldThatDiffers() {
        let decision = decide(pair(jpg: PhotoValue(stars: 3, flag: .pick), sidecar: PhotoValue(stars: 0, flag: .reject)), .rawWins)
        #expect(decision.value == PhotoValue(stars: 3, flag: .reject))
    }

    @Test func eachKindHasItsOwnChoice() {
        let item = pair(jpg: stars(1), sidecar: stars(4))
        #expect(Determiner.decide(item, settings: settings(flagConflict, .highest)).isIgnored)
        #expect(!decide(item, .highest).isIgnored)
    }
}

struct OneByOneTests {
    private let item = pair(jpg: PhotoValue(stars: 1, flag: .pick), sidecar: PhotoValue(stars: 4, flag: .reject))

    private func decided(_ override: PhotoOverride?) -> PhotoDecision {
        var values = settings(Determiner.decide(item).conflict!, .oneByOne)
        if let override { values.overrides[item.photo.listKey] = override }
        return Determiner.decide(item, settings: values)
    }

    @Test func itStartsWithTheHighestRatedSource() {
        #expect(decided(nil).value == PhotoValue(stars: 4, flag: .reject))
        #expect(!decided(nil).isIgnored)
    }

    @Test func aSourceSetsBothStarsAndFlag() {
        #expect(decided(.source(.jpg)).value == PhotoValue(stars: 1, flag: .pick))
        #expect(decided(.source(.raw)).value == PhotoValue(stars: 4, flag: .reject))
    }

    @Test func newSetsBothByHand() {
        let value = PhotoValue(stars: 5, flag: Flag.none)
        let decision = decided(.new(value))
        #expect(decision.value == value)
        #expect(decision.changesImage)
        #expect(decision.changesSidecar)
    }

    @Test func aChoiceForAPhotoOnlyCountsWhileTheKindIsOneByOne() {
        var values = settings(Determiner.decide(item).conflict!, .highest)
        values.overrides[item.photo.listKey] = .source(.jpg)
        #expect(Determiner.decide(item, settings: values).value.stars == 4)
    }

    @Test func thePhotoStaysInItsConflict() {
        #expect(decided(.source(.jpg)).conflict != nil)
    }

    @Test func thePreselectedSourceHasTheHighestRating() {
        #expect(PhotoSources(jpg: stars(1), raw: stars(4)).preselected == .raw)
        #expect(PhotoSources(jpg: stars(4), raw: stars(2)).preselected == .jpg)
    }

    /// A JPG's rating of 0 won from a RAW with no rating field and a pick.
    @Test(arguments: [Flag.pick, .reject])
    func aFlagBeatsNoFlagWhenNeitherHasARating(flagged: Flag) {
        #expect(PhotoSources(jpg: stars(0), raw: flag(flagged)).preselected == .raw)
        #expect(PhotoSources(jpg: .empty, raw: flag(flagged)).preselected == .raw)
    }

    @Test func aTieGoesToTheHigherFlagThenTheJPG() {
        #expect(PhotoSources(jpg: stars(2), raw: PhotoValue(stars: 2, flag: .pick)).preselected == .raw)
        #expect(PhotoSources(jpg: stars(2), raw: stars(2)).preselected == .jpg)
    }
}

struct WhatChangesTests {
    @Test func aPairWithARatedJPGGetsARating() {
        let decision = Determiner.decide(pair(jpg: stars(2)))
        #expect(decision.changesSidecar)
        #expect(decision.createsSidecar)
    }

    @Test func aRAWWithNothingToStoreGetsNoSidecar() {
        #expect(!Determiner.decide(rawOnly()).changesSidecar)
    }

    @Test func anExistingSidecarThatDiffersIsChangedNotCreated() {
        let decision = decide(pair(jpg: stars(3), sidecar: stars(1)), .jpgWins)
        #expect(decision.changesSidecar)
        #expect(!decision.createsSidecar)
    }

    @Test func aForcedValueSetsAnyPhoto() {
        let decision = Determiner.decide(jpgOnly(stars(2)), setting: PhotoValue(stars: 0, flag: nil))
        #expect(decision.value.stars == 0)
        #expect(decision.changesImage)
    }

    @Test func anUnreadableSourceLeavesThePhotoAlone() {
        let item = ScannedPhoto(photo: pair().photo, image: .value(stars(3)), sidecar: .unreadable)
        let decision = Determiner.decide(item, settings: settings(ratingConflict, .highest))
        #expect(decision.isSkipped)
        #expect(decision.conflict == nil)
        #expect(!decision.changesImage)
        #expect(!decision.changesSidecar)
    }

    @Test func aFieldNoFileHoldsCountsAsUnratedForTheList() {
        #expect(Determiner.decide(pair()).valueForList == PhotoValue(stars: 0, flag: Flag.none))
    }

    @Test func countsAddUpPerFolderAndInTotal() {
        let scan = ScanResult(folders: [
            FolderScan(folder: folder, photos: [pair(jpg: stars(2)), pair(sidecar: stars(2))], unreadableFolders: []),
            FolderScan(folder: folder, photos: [
                pair(jpg: stars(3), sidecar: stars(1)),
                ScannedPhoto(photo: jpgOnly().photo, image: .unreadable, sidecar: .absent),
            ], unreadableFolders: []),
        ])
        let result = Determiner.determine(scan)

        let rawOnly = ConflictType(jpgStars: nil, rawStars: 2, jpgFlag: nil, rawFlag: nil)!
        let jpgHigher = ConflictType(jpgStars: 3, rawStars: 1, jpgFlag: nil, rawFlag: nil)!

        var first = DecisionCounts()
        first.conflicts[rawOnly] = 1
        first.ignored = 1
        first.jpgsToRaws = 1
        first.sidecarsToCreate = 1
        #expect(result.folders[0].counts == first)

        var total = first
        total.conflicts[jpgHigher] = 1
        total.ignored = 2
        total.skipped = 1
        #expect(result.counts == total)
    }
}

struct PerFolderTests {
    private func photo(_ folder: String, jpg: PhotoValue, raw: PhotoValue) -> ScannedPhoto {
        ScannedPhoto(
            photo: Photo(
                kind: .pair,
                imageURL: URL(fileURLWithPath: "\(folder)/a.JPG"),
                rawURL: URL(fileURLWithPath: "\(folder)/a.RAF"),
                sidecarURL: URL(fileURLWithPath: "\(folder)/a.xmp")
            ),
            image: .value(jpg),
            sidecar: .value(raw)
        )
    }

    private let winter = "/photos/2026/winter 26"
    private let zomer = "/photos/2026/zomer 26"

    @Test func aFoldersChoiceOverridesTheChoiceForAll() {
        var values = settings(ratingConflict, .highest)
        values.set(ratingConflict, folder: winter, to: .lowest)
        #expect(Determiner.decide(photo(winter, jpg: stars(1), raw: stars(4)), settings: values).value.stars == 1)
        #expect(Determiner.decide(photo(zomer, jpg: stars(1), raw: stars(4)), settings: values).value.stars == 4)
    }

    @Test func aFoldersChoiceOnlyCountsForItsKind() {
        var values = ConflictSettings()
        values.set(flagConflict, folder: winter, to: .highest)
        #expect(Determiner.decide(photo(winter, jpg: stars(1), raw: stars(4)), settings: values).isIgnored)
    }

    @Test func aFolderLeftOnIgnoreStaysAloneWhileAnotherIsDecided() {
        var values = ConflictSettings()
        values.set(ratingConflict, folder: zomer, to: .highest)
        let scan = ScanResult(folders: [FolderScan(folder: URL(fileURLWithPath: "/photos"), photos: [
            photo(winter, jpg: stars(1), raw: stars(4)),
            photo(zomer, jpg: stars(1), raw: stars(4)),
        ], unreadableFolders: [])])
        let counts = Determiner.determine(scan, settings: values).counts
        #expect(counts.ignored == 1)
        #expect(counts.rawsToJpgs == 1)
    }

    @Test func oneFolderDecidedOneByOneTakesThePreselectedSource() {
        var values = settings(ratingConflict, .ignore)
        values.set(ratingConflict, folder: winter, to: .oneByOne)
        #expect(Determiner.decide(photo(winter, jpg: stars(1), raw: stars(4)), settings: values).value.stars == 4)
        #expect(Determiner.decide(photo(zomer, jpg: stars(1), raw: stars(4)), settings: values).isIgnored)
    }

    @Test func aChoiceIsMixedWhenFoldersDiffer() {
        var values = settings(ratingConflict, .highest)
        #expect(values.overall(for: ratingConflict, folders: [winter, zomer]) == .highest)
        values.set(ratingConflict, folder: winter, to: .lowest)
        #expect(values.overall(for: ratingConflict, folders: [winter, zomer]) == nil)
        values.set(ratingConflict, folders: [winter, zomer], to: .lowest)
        #expect(values.overall(for: ratingConflict, folders: [winter, zomer]) == .lowest)
    }

    @Test func settingTheMainChoiceReplacesTheFolderChoicesOfThatKindOnly() {
        var values = ConflictSettings()
        values.set(ratingConflict, folder: winter, to: .lowest)
        values.set(flagConflict, folder: winter, to: .lowest)
        values.setAll(ratingConflict, to: .highest)
        #expect(values.choice(for: ratingConflict, folder: winter) == .highest)
        #expect(values.choice(for: flagConflict, folder: winter) == .lowest)
    }

    private var scan: ScanResult {
        ScanResult(folders: [
            FolderScan(folder: URL(fileURLWithPath: "/photos/bibliotheek"), photos: [
                photo("/photos/bibliotheek/2026/winter 26", jpg: PhotoValue(stars: 3, flag: .pick), raw: stars(1)),
                photo("/photos/bibliotheek/2026/zomer 26", jpg: stars(1), raw: stars(4)),
                photo("/photos/bibliotheek/XXXX/winter 26", jpg: stars(2), raw: stars(0)),
                photo("/photos/bibliotheek", jpg: stars(0), raw: stars(0)),
            ], unreadableFolders: []),
        ])
    }

    @Test func theTreeStartsAtTheScannedFolderAndAddsUp() throws {
        let tops = SummaryTrees.ratings(in: scan)
        let top = try #require(tops.first)
        #expect(tops.count == 1)
        #expect(top.name == "bibliotheek")
        #expect(top.value.photos == 4)
        #expect(top.children.map(\.name) == ["2026", "XXXX"])

        let year = top.children[0]
        #expect(year.value.photos == 2)
        #expect(year.value.stars[3] == 1)
        #expect(year.value.picks == 1)
        #expect(year.children.map(\.name) == ["winter 26", "zomer 26"])
        #expect(year.children[0].children.isEmpty)
    }

    @Test func aChoiceOnAFolderCoversTheFoldersUnderIt() throws {
        let top = try #require(SummaryTrees.ratings(in: scan).first)
        #expect(top.children[0].paths.sorted() == [
            "/photos/bibliotheek/2026/winter 26", "/photos/bibliotheek/2026/zomer 26",
        ])
        #expect(top.paths.contains("/photos/bibliotheek"))
    }

    @Test func aConflictTreeListsOnlyFoldersWithThatKind() throws {
        let trees = SummaryTrees.conflicts(in: Determiner.determine(scan), scan: scan)
        let top = try #require(trees[ratingConflict]?.first)
        #expect(top.value == 1)
        #expect(top.children.map(\.name) == ["2026"])
        #expect(top.children[0].children.map(\.name) == ["zomer 26"])
    }

    @Test func twoScannedFoldersGiveTwoTops() {
        let two = ScanResult(folders: [
            FolderScan(folder: URL(fileURLWithPath: "/photos/b"), photos: [photo("/photos/b", jpg: stars(1), raw: stars(1))], unreadableFolders: []),
            FolderScan(folder: URL(fileURLWithPath: "/photos/a"), photos: [photo("/photos/a/x", jpg: stars(1), raw: stars(1))], unreadableFolders: []),
        ])
        #expect(SummaryTrees.ratings(in: two).map(\.name) == ["a", "b"])
    }
}

struct RatingTableTests {
    @Test func photosCountByTypeAndRatingAndAPairByItsJPG() {
        let table = RatingTable([
            jpgOnly(PhotoValue(stars: 2, flag: .reject)),
            rawOnly(sidecar: PhotoValue(stars: 5, flag: .pick)),
            rawOnly(),
            pair(jpg: PhotoValue(stars: 3, flag: .pick), sidecar: stars(1)),
            pair(),
            ScannedPhoto(photo: jpgOnly().photo, image: .unreadable, sidecar: .absent),
        ])
        #expect(table.jpgOnly.photos == 1)
        #expect(table.jpgOnly.stars[2] == 1)
        #expect(table.jpgOnly.rejects == 1)
        #expect(table.rawOnly.photos == 2)
        #expect(table.rawOnly.stars[5] == 1)
        #expect(table.rawOnly.stars[0] == 1)
        #expect(table.pairs.photos == 2)
        #expect(table.pairs.stars[3] == 1)
        #expect(table.pairs.stars[1] == 0)
        #expect(table.pairs.picks == 1)
        #expect(table.unreadable == 1)
    }
}

struct ActionTextTests {
    private func counts(toRaws: Int = 0, toJpgs: Int = 0, ignored: Int = 0) -> DecisionCounts {
        var counts = DecisionCounts()
        counts.jpgsToRaws = toRaws
        counts.rawsToJpgs = toJpgs
        counts.ignored = ignored
        return counts
    }

    private var listChange: ListChanges {
        var changes = ListChanges()
        changes.ratingsAdded = 1
        return changes
    }

    @Test func saveSaysWhatItCopies() {
        #expect(ActionText.save(counts()) == ("Nothing to change", false))
        #expect(ActionText.save(counts(toRaws: 35)) == ("Copy rating of 35 JPGs to their RAW", true))
        #expect(ActionText.save(counts(toRaws: 1)) == ("Copy rating of 1 JPG to its RAW", true))
        #expect(ActionText.save(counts(toJpgs: 2)) == ("Copy rating of 2 RAWs to their JPG", true))
        #expect(ActionText.save(counts(toRaws: 35, toJpgs: 1)) == ("Copy rating of 35 JPGs to their RAW, and of 1 RAW to its JPG", true))
    }

    @Test func saveCanRunWithIgnoredConflicts() {
        #expect(ActionText.save(counts(toRaws: 3, ignored: 2)).isEnabled)
    }

    /// You may want to leave some conflicts to decide on in Photomator.
    @Test func loadRunsWithIgnoredConflicts() {
        #expect(ActionText.load(counts(ignored: 1), listChanges: listChange) == ("Update Photomator", true))
        #expect(ActionText.load(counts(toRaws: 3, ignored: 2), listChanges: listChange)
            == ("Copy rating of 3 JPGs to their RAW, then update Photomator", true))
        #expect(ActionText.load(counts(ignored: 2), listChanges: ListChanges()) == ("Nothing to change", false))
    }

    @Test func theWarningSaysHowManyAreLeftOut() {
        #expect(ListText.ignoredWarning(1) == "1 photo with a conflict will not be updated in Photomator.")
        #expect(ListText.ignoredWarning(2) == "2 photos with a conflict will not be updated in Photomator.")
    }

    @Test func loadSaysWhatItDoes() {
        #expect(ActionText.load(counts(), listChanges: ListChanges()) == ("Nothing to change", false))
        #expect(ActionText.load(counts(), listChanges: listChange) == ("Update Photomator", true))
        #expect(ActionText.load(counts(toRaws: 3), listChanges: listChange)
            == ("Copy rating of 3 JPGs to their RAW, then update Photomator", true))
    }
}

struct ListTextTests {
    private func decision(_ path: String, _ value: PhotoValue) -> PhotoDecision {
        let photo = Photo(kind: .embedded, imageURL: URL(fileURLWithPath: path), rawURL: nil, sidecarURL: nil)
        return Determiner.decide(ScannedPhoto(photo: photo, image: .value(value), sidecar: .absent))
    }

    @Test func everyPhotoThatGetsANewValueInTheListCounts() {
        let list = PhotomatorList(
            ratings: ["/a/differs.JPG": 2, "/a/same.JPG": 3, "/a/onlyInList.JPG": 4],
            flags: ["/a/same.JPG": .pick],
            sidebarFolders: ["/a"]
        )
        let count = ListText.photosToUpdate([
            decision("/a/differs.JPG", stars(5)),
            decision("/a/same.JPG", PhotoValue(stars: 3, flag: .pick)),
            decision("/a/onlyInList.JPG", .empty),
            decision("/a/onlyInPhotos.JPG", stars(1)),
            decision("/a/nothing.JPG", .empty),
        ], list: list)
        #expect(count == 3)
    }

    @Test func theTextSaysHowMany() {
        #expect(ListText.willUpdate(1) == "The value of 1 photo will be updated in Photomator.")
        #expect(ListText.willUpdate(10) == "The value of 10 photos will be updated in Photomator.")
    }
}
