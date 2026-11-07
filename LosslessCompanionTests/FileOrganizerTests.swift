//
//  FileOrganizerTests.swift
//  LosslessCompanionTests
//

import Combine
import XCTest
@testable import LosslessCompanion

final class FileOrganizerTests: XCTestCase {
    private var folder: URL!
    private var support: URL!
    private var library: URL!

    override func setUpWithError() throws {
        // 掃描得到的是解開捷徑後的路徑，/var 會變成 /private/var
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        folder = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("organize-\(UUID().uuidString)")
        support = folder.appendingPathComponent("support")
        library = folder.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func file(_ name: String, contents: String? = nil) throws -> String {
        let url = library.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents ?? name).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func path(_ name: String) -> String {
        library.appendingPathComponent(name).path
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOfFile: path(name), encoding: .utf8)
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
    }

    // MARK: Names

    func testSanitizedNameUsesFullWidthForms() {
        XCTAssertEqual(FileNamer.sanitized("AC/DC: Back? *Live*"), "AC／DC： Back？ ＊Live＊")
        XCTAssertEqual(FileNamer.sanitized("  .hidden name.  "), "hidden name")
    }

    func testLongNameIsCutAtCharacterBoundary() {
        let name = FileNamer.fileName(stem: String(repeating: "夜に駆ける", count: 40), extension: "flac")
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix("る.flac") || name.hasSuffix(".flac"))
        XCTAssertEqual(String(decoding: Data(name.utf8), as: UTF8.self), name)
    }

    func testTemplatesLeaveOutMissingParts() {
        let track = makeTrack(title: "Song", path: "/m/old name.flac")
        let stem = { (template: FileNameTemplate, number: Int) in
            template.stem(of: track, title: "Song", artist: "Artist", number: number, disc: 2)
        }
        XCTAssertEqual(stem(.trackTitle, 3), "03 Song")
        XCTAssertEqual(stem(.trackTitle, 0), "Song")
        XCTAssertEqual(stem(.discTrackTitle, 3), "2-03 Song")
        XCTAssertEqual(stem(.trackArtistTitle, 3), "03 Artist - Song")
        XCTAssertEqual(stem(.artistTitle, 3), "Artist - Song")
        XCTAssertEqual(stem(.unchanged, 3), "old name")
    }

    // MARK: Plans

    func testPlanRefusesToOverwrite() throws {
        let from = try file("a.flac")
        try file("b.flac")
        XCTAssertThrowsError(try MovePlan(moves: [FileMove(from: from, to: path("b.flac"))])) {
            XCTAssertEqual($0 as? OrganizeError, .destinationExists("b.flac"))
        }
    }

    func testPlanRefusesTwoFilesWithTheSameName() throws {
        let moves = [FileMove(from: try file("a.flac"), to: path("c.flac")), FileMove(from: try file("b.flac"), to: path("C.flac"))]
        XCTAssertThrowsError(try MovePlan(moves: moves)) {
            XCTAssertEqual($0 as? OrganizeError, .duplicateDestination("C.flac"))
        }
    }

    func testPlanReportsMissingFile() {
        XCTAssertThrowsError(try MovePlan(moves: [FileMove(from: path("gone.flac"), to: path("x.flac"))])) {
            XCTAssertEqual($0 as? OrganizeError, .missing("gone.flac"))
        }
    }

    func testPlanSkipsUnchangedNames() throws {
        let from = try file("a.flac")
        XCTAssertTrue(try MovePlan(moves: [FileMove(from: from, to: from)]).steps.isEmpty)
    }

    // MARK: Running

    func testSwappedNames() throws {
        let organizer = LibraryOrganizer(directory: support)
        let moves = [FileMove(from: try file("a.flac", contents: "A"), to: path("b.flac")),
                     FileMove(from: try file("b.flac", contents: "B"), to: path("a.flac"))]
        _ = try organizer.run(OrganizeRequest(title: "t", moves: moves))
        XCTAssertEqual(try read("a.flac"), "B")
        XCTAssertEqual(try read("b.flac"), "A")
        XCTAssertEqual(try names(), ["a.flac", "b.flac"])
    }

    func testChainOfNames() throws {
        let organizer = LibraryOrganizer(directory: support)
        let moves = [FileMove(from: try file("1.flac", contents: "one"), to: path("2.flac")),
                     FileMove(from: try file("2.flac", contents: "two"), to: path("3.flac"))]
        _ = try organizer.run(OrganizeRequest(title: "t", moves: moves))
        XCTAssertEqual(try read("2.flac"), "one")
        XCTAssertEqual(try read("3.flac"), "two")
    }

    func testCaseOnlyRename() throws {
        let organizer = LibraryOrganizer(directory: support)
        _ = try organizer.run(OrganizeRequest(title: "t", moves: [FileMove(from: try file("song.flac"), to: path("Song.flac"))]))
        XCTAssertEqual(try names(), ["Song.flac"])
    }

    func testFailureRollsBackEverything() throws {
        let organizer = LibraryOrganizer(directory: support)
        let blocker = try file("blocker")
        let moves = [FileMove(from: try file("a.flac", contents: "A"), to: path("renamed.flac")),
                     // 目的地的上層是檔案，到執行時才會失敗
                     FileMove(from: try file("b.flac", contents: "B"), to: blocker + "/inside.flac")]
        XCTAssertThrowsError(try organizer.run(OrganizeRequest(title: "t", moves: moves)))
        XCTAssertEqual(try read("a.flac"), "A")
        XCTAssertEqual(try read("b.flac"), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("renamed.flac")))
    }

    func testUndoRestoresNames() throws {
        let organizer = LibraryOrganizer(directory: support)
        let outcome = try organizer.run(OrganizeRequest(title: "t", moves: [FileMove(from: try file("a.flac", contents: "A"), to: path("b.flac"))]))
        organizer.finish(outcome.record)
        XCTAssertEqual(organizer.history.count, 1)

        _ = try organizer.undo(outcome.record)
        organizer.finish(undoing: outcome.record)
        XCTAssertEqual(try read("a.flac"), "A")
        XCTAssertTrue(organizer.history.isEmpty)
    }

    func testUndoStopsWhenFileIsGone() throws {
        let organizer = LibraryOrganizer(directory: support)
        let outcome = try organizer.run(OrganizeRequest(title: "t", moves: [FileMove(from: try file("a.flac"), to: path("b.flac"))]))
        try FileManager.default.removeItem(atPath: path("b.flac"))
        XCTAssertThrowsError(try organizer.undo(outcome.record)) {
            XCTAssertEqual($0 as? OrganizeError, .undoConflict("b.flac"))
        }
    }

    func testUndoDoesNotOverwriteANewFile() throws {
        let organizer = LibraryOrganizer(directory: support)
        let outcome = try organizer.run(OrganizeRequest(title: "t", moves: [FileMove(from: try file("a.flac", contents: "old"), to: path("b.flac"))]))
        try file("a.flac", contents: "new")
        XCTAssertThrowsError(try organizer.undo(outcome.record))
        XCTAssertEqual(try read("a.flac"), "new")
        XCTAssertEqual(try read("b.flac"), "old")
    }

    func testHistorySurvivesRestart() throws {
        let organizer = LibraryOrganizer(directory: support)
        let outcome = try organizer.run(OrganizeRequest(title: "整理", moves: [FileMove(from: try file("a.flac"), to: path("b.flac"))]))
        organizer.finish(outcome.record)
        XCTAssertEqual(LibraryOrganizer(directory: support).history, [outcome.record])
    }

    func testRecoveryFinishesInterruptedRun() throws {
        let plan = try MovePlan(moves: [FileMove(from: try file("a.flac", contents: "A"), to: path("x.flac")),
                                        FileMove(from: try file("b.flac", contents: "B"), to: path("y.flac"))])
        try JSONEncoder().encode(plan).write(to: support.appendingPathComponent("organize-journal-v1.json"))
        // 當掉之前只做完第一步
        try FileManager.default.moveItem(atPath: path("a.flac"), toPath: path("x.flac"))

        let organizer = LibraryOrganizer(directory: support)
        XCTAssertEqual(organizer.recover().count, 2)
        XCTAssertEqual(try read("x.flac"), "A")
        XCTAssertEqual(try read("y.flac"), "B")
        XCTAssertTrue(organizer.recover().isEmpty)
    }

    func testTagFailureLeavesOtherFilesDone() throws {
        let organizer = LibraryOrganizer(directory: support)
        let broken = try file("broken.flac", contents: "not audio")
        let outcome = try organizer.run(OrganizeRequest(title: "t", moves: [FileMove(from: broken, to: path("renamed.flac"))],
                                                        tags: [(broken, TagUpdate(title: "x"))]))
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.record.tags.isEmpty)
        XCTAssertEqual(try read("renamed.flac"), "not audio")
    }

    // MARK: Rows

    private func entry(title: String = "Song", artist: String = "Artist", album: String = "Album", number: Int = 1,
                       disc: Int = 1, year: Int = 2020) -> MusicPlaylistEntry {
        MusicPlaylistEntry(position: 0, trackID: "AAAA", title: title, artist: artist, albumArtist: "", album: album, duration: 200,
                           trackNumber: number, discNumber: disc, year: year, cloudStatus: "subscription", genre: "J-Pop", composer: "")
    }

    func testUpdateOnlyHasDifferences() {
        var track = makeTrack(title: "Song")
        track.year = 2020
        track.genre = "JPOP"
        XCTAssertTrue(OrganizePlanner.update(for: track, from: entry()).isEmpty)
        let update = OrganizePlanner.update(for: track, from: entry(title: "新歌名", number: 5, year: 2021))
        XCTAssertEqual(update, TagUpdate(title: "新歌名", trackNumber: 5, year: 2021))
    }

    func testEmptyMusicFieldsDoNotClearFileTags() {
        var track = makeTrack(title: "Song")
        track.albumArtist = "Someone"
        track.composer = "Composer"
        track.year = 2020
        track.genre = "J-Pop"
        XCTAssertTrue(OrganizePlanner.update(for: track, from: entry()).isEmpty)
    }

    func testCatalogSuffixIsNotAnAlbumChange() {
        var track = makeTrack(title: "Song", album: "次等秘密")
        track.year = 2020
        track.genre = "J-Pop"
        XCTAssertNil(OrganizePlanner.update(for: track, from: entry(album: "次等秘密 - Single")).album)
        XCTAssertEqual(OrganizePlanner.update(for: track, from: entry(album: "別的專輯")).album, "別的專輯")
    }

    func testRowsFallBackToFileTagsWithoutMatch() {
        let track = makeTrack(title: "Local", number: 3, path: "/m/x.flac")
        let rows = OrganizePlanner.rows(for: [track], apple: [:], source: .appleMusic, template: .trackTitle)
        XCTAssertFalse(rows[0].usesAppleMusic)
        XCTAssertEqual(rows[0].stem, "03 Local")
        XCTAssertTrue(rows[0].update.isEmpty)
    }

    func testRowsUseMusicData() {
        let track = makeTrack(title: "Old", number: 3, path: "/m/x.flac")
        let rows = OrganizePlanner.rows(for: [track], apple: [track.path: entry(title: "New", number: 4)], source: .appleMusic, template: .trackTitle)
        XCTAssertEqual(rows[0].stem, "04 New")
        XCTAssertTrue(rows[0].changes.contains("歌名：Old → New"))
    }

    func testFileTagsSourceIgnoresMusic() {
        let track = makeTrack(title: "Old", number: 3, path: "/m/x.flac")
        let rows = OrganizePlanner.rows(for: [track], apple: [track.path: entry(title: "New")], source: .fileTags, template: .trackTitle)
        XCTAssertEqual(rows[0].stem, "03 Old")
        XCTAssertTrue(rows[0].update.isEmpty)
    }

    func testMultiDiscAlbumDefaultsToDiscPrefix() {
        var second = makeTrack(title: "B")
        second.discNumber = 2
        XCTAssertEqual(OrganizePlanner.defaultTemplate(for: [makeTrack(title: "A"), second]), .discTrackTitle)
        XCTAssertEqual(OrganizePlanner.defaultTemplate(for: [makeTrack(title: "A")]), .trackTitle)
    }

    // MARK: Keeping references

    func testDecisionsFollowRename() {
        var decisions = MatchDecisions()
        let linked = makeTrack(title: "A", path: "/m/a.flac")
        let local = makeTrack(title: "B", path: "/m/b.flac")
        decisions.link(linked, to: entry())
        decisions.markLocalOnly(local.path)
        decisions.apply([FileMove(from: linked.path, to: "/m/new-a.flac"), FileMove(from: local.path, to: "/m/new-b.flac")])

        XCTAssertNil(decisions.links["/m/a.flac"])
        XCTAssertEqual(decisions.links["/m/new-a.flac"]?.path, "/m/new-a.flac")
        XCTAssertEqual(decisions.links["/m/new-a.flac"]?.trackID, "AAAA")
        XCTAssertEqual(decisions.localOnly, ["/m/new-b.flac"])
    }

    func testPlayCountsFollowRename() {
        let store = PlayCountStore(directory: support)
        store.recordPlay(of: "/m/a.flac")
        store.recordPlay(of: "/m/a.flac")
        store.apply([FileMove(from: "/m/a.flac", to: "/m/b.flac")])
        XCTAssertEqual(store.count(for: "/m/b.flac"), 2)
        XCTAssertEqual(PlayCountStore(directory: support).count(for: "/m/b.flac"), 2)
        XCTAssertEqual(store.count(for: "/m/a.flac"), 0)
    }

    func testMovedTrackIsFoundByNewName() {
        let track = makeTrack(title: "Song", path: "/m/old/file.flac")
        let moved = track.moved(to: "/m/new/renamed.flac")
        XCTAssertEqual(moved.path, "/m/new/renamed.flac")
        XCTAssertTrue(moved.searchKey.contains("renamed"))
        XCTAssertFalse(moved.searchKey.contains("file"))
    }

    func testLibraryKeepsTrackAfterMoveWithoutInspecting() throws {
        let cache = support.appendingPathComponent("library.json")
        let library = LocalLibrary(folders: [self.library.path], cacheURL: cache)
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        var bytes = [UInt8]()
        func u32(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)] }
        let samples = [UInt8](repeating: 1, count: 44_100 * 4)
        let format: [UInt8] = [1, 0, 2, 0] + u32(44_100) + u32(176_400) + [4, 0, 16, 0]
        bytes = Array("WAVE".utf8) + Array("fmt ".utf8) + u32(16) + format + Array("data".utf8) + u32(samples.count) + samples
        bytes = Array("RIFF".utf8) + u32(bytes.count) + bytes
        let old = self.library.appendingPathComponent("01 Old.wav")
        try Data(bytes).write(to: old)

        library.scan(folders: [self.library.path])
        library.publishNow()
        XCTAssertEqual(library.tracks.map(\.path), [old.path])

        let new = self.library.appendingPathComponent("02 New.wav").path
        try FileManager.default.moveItem(atPath: old.path, toPath: new)
        library.applyMoves([FileMove(from: old.path, to: new)])
        XCTAssertEqual(library.tracks.map(\.path), [new])
        XCTAssertEqual(library.tracks.first?.title, "Old")

        // 大小與時間沒變，再掃描也沿用索引，標籤版本相同時不重讀
        library.scan(folders: [self.library.path])
        library.publishNow()
        XCTAssertEqual(library.tracks.first?.title, "Old")

        library.markOutdated([new])
        library.scan(folders: [self.library.path])
        library.publishNow()
        XCTAssertEqual(library.tracks.first?.title, "New")
    }
}

final class AlbumMergeTests: XCTestCase {
    private func track(_ title: String, folder: String, number: Int, disc: Int = 1) -> LibraryTrack {
        var track = makeTrack(title: title, album: URL(fileURLWithPath: folder).lastPathComponent, number: number,
                              path: "\(folder)/\(number) \(title).flac")
        track.discNumber = disc
        return track
    }

    private func album(_ tracks: [LibraryTrack], id: String) -> AlbumGroup {
        AlbumGroup(id: id, title: tracks[0].album, artist: "Artist", tracks: tracks, addedAt: 0)
    }

    func testMergedFoldersBecomeOneAlbum() {
        let tracks = [track("A", folder: "/m/Part1", number: 1), track("B", folder: "/m/Part2", number: 1), track("C", folder: "/m/Other", number: 1)]
        var merges = AlbumMerges()
        merges.merge(target: "/m/Part1", sources: ["/m/Part2"], title: "Whole")
        let index = LibraryIndex.build(tracks: tracks, addedAt: [:], apple: [:], merges: merges)

        XCTAssertEqual(index.albums.count, 2)
        let merged = index.albums.first { $0.id == "/m/Part1" }
        XCTAssertEqual(merged?.title, "Whole")
        XCTAssertEqual(merged?.tracks.map(\.title), ["A", "B"])
        XCTAssertEqual(index.albumsByID["/m/Part2"]?.id, "/m/Part1")
        XCTAssertEqual(index.albumsByPath["/m/Part2/1 B.flac"]?.id, "/m/Part1")
    }

    func testMergedTracksKeepFolderOrderInsteadOfInterleaving() {
        let tracks = [track("A1", folder: "/m/B", number: 1), track("A2", folder: "/m/B", number: 2),
                      track("B1", folder: "/m/A", number: 1), track("B2", folder: "/m/A", number: 2)]
        var merges = AlbumMerges()
        merges.merge(target: "/m/B", sources: ["/m/A"], title: nil)
        let album = LibraryIndex.build(tracks: tracks, addedAt: [:], apple: [:], merges: merges).albums[0]
        XCTAssertEqual(album.tracks.map(\.title), ["A1", "A2", "B1", "B2"])
    }

    func testDiscSubfolderTracksDoNotInterleave() {
        let tracks = [track("A1", folder: "/m/Album", number: 1), track("B1", folder: "/m/Album/Disc 2", number: 1),
                      track("A2", folder: "/m/Album", number: 2), track("B2", folder: "/m/Album/Disc 2", number: 2)]
        let albums = LibraryBrowser.albums(from: tracks, addedAt: [:])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].tracks.map(\.title), ["A1", "A2", "B1", "B2"])
    }

    func testMergingAMergedAlbumFlattensIt() {
        var merges = AlbumMerges()
        merges.merge(target: "/b", sources: ["/c"], title: "BC")
        merges.merge(target: "/a", sources: ["/b"], title: nil)
        XCTAssertEqual(merges.merge(containing: "/c")?.folders, ["/a", "/b", "/c"])
        XCTAssertEqual(merges.merges.count, 1)
    }

    func testRemovingOneMergeKeepsEarlierOnes() {
        var merges = AlbumMerges()
        merges.merge(target: "/a", sources: ["/b"], title: nil)
        merges.merge(target: "/a", sources: ["/c"], title: nil)
        merges.remove(folders: ["/c"], from: "/a")
        XCTAssertEqual(merges.merge(containing: "/a")?.folders, ["/a", "/b"])
        merges.remove(folders: ["/b"], from: "/a")
        XCTAssertNil(merges.merge(containing: "/a"))
    }

    func testMergeStoreSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        AlbumMergeStore(directory: directory).merge(target: "/a", sources: ["/b"], title: "T")
        XCTAssertEqual(AlbumMergeStore(directory: directory).merges.merge(containing: "/b")?.title, "T")
    }

    func testFilesGoDirectlyIntoTargetWhenNothingOverlaps() {
        let target = album([track("A", folder: "/m/T", number: 1)], id: "/m/T")
        let source = album([track("B", folder: "/m/S", number: 2)], id: "/m/S")
        XCTAssertEqual(AlbumMergePlanner.moves(into: target, from: [source], exists: { _ in false }),
                       [FileMove(from: "/m/S/2 B.flac", to: "/m/T/2 B.flac")])
    }

    func testOverlappingNumbersGoToDiscFolder() {
        let target = album([track("A", folder: "/m/T", number: 1)], id: "/m/T")
        let source = album([track("B", folder: "/m/S", number: 1)], id: "/m/S")
        XCTAssertEqual(AlbumMergePlanner.moves(into: target, from: [source], exists: { _ in false }),
                       [FileMove(from: "/m/S/1 B.flac", to: "/m/T/Disc 2/1 B.flac")])
    }

    func testExistingDiscFolderIsSkipped() {
        let target = album([track("A", folder: "/m/T", number: 1)], id: "/m/T")
        let source = album([track("B", folder: "/m/S", number: 1)], id: "/m/S")
        let moves = AlbumMergePlanner.moves(into: target, from: [source], exists: { $0 == "/m/T/Disc 2" })
        XCTAssertEqual(moves.first?.to, "/m/T/Disc 3/1 B.flac")
    }

    func testSameAlbumIsSuggestedFirst() {
        let album = AlbumGroup(id: "/1", title: "魚大図鑑", artist: "サカナクション", tracks: [makeTrack(title: "A")], addedAt: 0)
        let other = AlbumGroup(id: "/2", title: "Another", artist: "Someone", tracks: [makeTrack(title: "B")], addedAt: 0)
        let same = AlbumGroup(id: "/3", title: "魚大図鑑", artist: "サカナクション", tracks: [makeTrack(title: "C")], addedAt: 0)
        XCTAssertEqual(AlbumMergePlanner.candidates(for: album, in: [album, other, same]).map(\.id), ["/3", "/2"])
    }

    func testDuplicateTitlesAreCounted() {
        let first = album([track("A", folder: "/a", number: 1), track("B", folder: "/a", number: 2)], id: "/a")
        let second = album([track("A", folder: "/b", number: 1)], id: "/b")
        XCTAssertEqual(AlbumMergePlanner.duplicateCount(in: [first, second]), 1)
    }
}

final class AlbumRateTests: XCTestCase {
    private func album(_ id: String, rates: [Double]) -> AlbumGroup {
        let tracks = rates.enumerated().map { makeTrack(title: "T\($0.offset)", rate: $0.element, path: "\(id)/\($0.offset).flac") }
        return AlbumGroup(id: id, title: id, artist: "A", tracks: tracks, addedAt: 0)
    }

    func testRatesAreWrittenTheWayAlbumsShowThem() {
        XCTAssertEqual(Format.sampleRates([44_100]), "44.1 kHz")
        XCTAssertEqual(Format.sampleRates([96_000, 48_000]), "48/96 kHz")
        XCTAssertEqual(Format.sampleRates([44_100, 48_000, 96_000]), "44.1/48/96 kHz")
    }

    func testAlbumsAreGroupedByRateWithMixedOnesApart() {
        let albums = [album("/d", rates: [192_000]), album("/a", rates: [96_000, 48_000, 96_000]), album("/b", rates: [44_100]),
                      album("/c", rates: [48_000]), album("/e", rates: [44_100, 44_100])]
        let groups = LibraryBrowser.rateGroups(from: albums)
        XCTAssertEqual(groups.map(\.title), ["44.1 kHz", "48 kHz", "48/96 kHz", "192 kHz"])
        XCTAssertEqual(groups[0].albums.map(\.id), ["/b", "/e"])
        XCTAssertEqual(groups[2].albums.map(\.id), ["/a"])
    }

    func testRateSortKeepsTitleOrderInsideEachGroup() {
        let albums = AlbumSortKey.sampleRate.sorted([album("/b", rates: [48_000]), album("/a", rates: [48_000])])
        XCTAssertEqual(LibraryBrowser.rateGroups(from: albums)[0].albums.map(\.id), ["/a", "/b"])
    }
}

final class AlbumExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func albumFolder(_ name: String, files: [String: String]) throws -> AlbumGroup {
        let directory = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tracks = [LibraryTrack]()
        for (file, contents) in files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            if url.pathExtension == "flac" { tracks.append(makeTrack(title: url.deletingPathExtension().lastPathComponent, path: url.path)) }
        }
        return AlbumGroup(id: directory.path, title: name, artist: "歌手", tracks: tracks, addedAt: 0)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func wait(for job: ExportJob) {
        let done = expectation(description: "export")
        let observer = job.$state.sink { state in
            switch state {
            case .finished, .failed: done.fulfill()
            default: break
            }
        }
        wait(for: [done], timeout: 30)
        observer.cancel()
    }

    func testEntriesKeepSubfoldersAndCovers() throws {
        let album = try albumFolder("專輯", files: ["01 A.flac": "a", "Disc 2/01 B.flac": "b", "cover.jpg": "img", "notes.txt": "skip"])
        let paths = ExportPlanner.entries(for: [album], playCounts: [:]).map(\.path)
        XCTAssertEqual(Set(paths), ["歌手 - 專輯/01 A.flac", "歌手 - 專輯/Disc 2/01 B.flac", "歌手 - 專輯/cover.jpg", ExportPlanner.playCountFileName])
    }

    func testAlbumsWithTheSameNameStaySeparate() throws {
        let first = try albumFolder("one/Album", files: ["1.flac": "a"])
        let second = try albumFolder("two/Album", files: ["1.flac": "b"])
        let renamed = [first, second].map { AlbumGroup(id: $0.id, title: "Album", artist: "A", tracks: $0.tracks, addedAt: 0) }
        let paths = ExportPlanner.entries(for: renamed, playCounts: [:]).map(\.path)
        XCTAssertTrue(paths.contains("A - Album/1.flac"))
        XCTAssertTrue(paths.contains("A - Album 2/1.flac"))
    }

    func testMergedAlbumKeepsOtherFolderUnderItsName() throws {
        let first = try albumFolder("Part1", files: ["1.flac": "a"])
        let second = try albumFolder("Part2", files: ["1.flac": "b"])
        let merged = AlbumGroup(id: first.id, title: "All", artist: "A", tracks: first.tracks + second.tracks, addedAt: 0)
        let paths = ExportPlanner.entries(for: [merged], playCounts: [:]).map(\.path)
        XCTAssertTrue(paths.contains("A - All/1.flac"))
        XCTAssertTrue(paths.contains("A - All/Part2/1.flac"))
    }

    func testPlayCountsAreWrittenAsCSV() throws {
        let album = try albumFolder("Album", files: ["01 A, B.flac": "a"])
        let date = Date(timeIntervalSince1970: 0)
        let entries = ExportPlanner.entries(for: [album], playCounts: [album.tracks[0].path: PlayRecord(count: 7, lastPlayed: date)])
        guard case .text(let data) = entries.last?.item else { return XCTFail("沒有播放次數清單") }
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.contains("\"01 A, B\""))
        XCTAssertTrue(text.contains(",7,1970-01-01T00:00:00Z"))
    }

    func testZipIsReadableAndIdentical() throws {
        let album = try albumFolder("夜に駆ける", files: ["01 Flare.flac": String(repeating: "audio", count: 40_000), "cover.png": "png"])
        let job = ExportJob(entries: ExportPlanner.entries(for: [album], playCounts: [:]))
        let output = folder.appendingPathComponent("out.zip")
        job.start(destination: output)
        wait(for: job)
        XCTAssertEqual(job.state, .finished(output))
        XCTAssertEqual(try run("/usr/bin/unzip", ["-t", output.path]).status, 0)

        let extracted = folder.appendingPathComponent("extracted")
        XCTAssertEqual(try run("/usr/bin/ditto", ["-x", "-k", output.path, extracted.path]).status, 0)
        let name = "歌手 - 夜に駆ける/01 Flare.flac"
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(name)), try Data(contentsOf: album.tracks[0].url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(ExportPlanner.playCountFileName).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }, [])
    }

    func testNotEnoughSpaceIsReportedBeforeWriting() throws {
        let job = ExportJob(entries: [ExportEntry(path: "huge", item: .text(Data()), size: UInt64.max / 2)])
        let output = folder.appendingPathComponent("out.zip")
        job.start(destination: output)
        wait(for: job)
        guard case .failed(let reason) = job.state else { return XCTFail("應該要失敗") }
        XCTAssertTrue(reason.contains("空間不足"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelLeavesNothingBehind() throws {
        let big = folder.appendingPathComponent("big.flac")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 256 << 20)
        try handle.close()

        let job = ExportJob(entries: [ExportEntry(path: "big.flac", item: .file(big), size: 256 << 20)])
        job.cancel()
        let output = folder.appendingPathComponent("out.zip")
        let ready = expectation(description: "cancelled")
        var sawRunning = false
        let observer = job.$state.sink { state in
            if state == .running { sawRunning = true }
            if state == .ready, sawRunning { ready.fulfill() }
        }
        job.start(destination: output)
        wait(for: [ready], timeout: 30)
        observer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["big.flac"])
    }

    func testZip64FileIsReadable() throws {
        guard ProcessInfo.processInfo.environment["LC_ZIP64"] != nil else { throw XCTSkip("要寫超過 4 GB，平常不跑") }
        let big = folder.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        let size: UInt64 = (4 << 30) + 4096
        try handle.truncate(atOffset: size)
        try handle.close()

        let output = folder.appendingPathComponent("big.zip")
        let writer = try ZipWriter(url: output)
        try writer.add(path: "small.txt", data: Data("hello".utf8), modified: Date())
        try writer.add(path: "big.bin", file: big, size: size, modified: Date()) { _ in true }
        try writer.add(path: "after.txt", data: Data("world".utf8), modified: Date())
        try writer.finish()
        let result = try run("/usr/bin/python3", ["-I", "-c", """
        import sys, zipfile
        z = zipfile.ZipFile(sys.argv[1])
        print(z.testzip(), [(i.filename, i.file_size) for i in z.infolist()])
        print(z.read('after.txt'))
        """, output.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("None"), result.output)
        XCTAssertTrue(result.output.contains("b'world'"), result.output)
    }
}

final class FolderPlaylistTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(_ title: String, folder: String, number: Int) -> LibraryTrack {
        makeTrack(title: title, number: number, path: "\(folder)/\(number) \(title).flac")
    }

    func testPlaylistIsNamedAfterFolderAndSurvivesRestart() {
        let store = FolderPlaylistStore(directory: directory)
        let playlist = store.add(folder: "/m/JPOP/Ado")
        XCTAssertEqual(playlist.name, "Ado")
        XCTAssertEqual(FolderPlaylistStore(directory: directory).playlists, [playlist])
    }

    func testSameFolderIsNotAddedTwice() {
        let store = FolderPlaylistStore(directory: directory)
        XCTAssertEqual(store.add(folder: "/m/A").id, store.add(folder: "/m/A").id)
        XCTAssertEqual(store.playlists.count, 1)
    }

    func testRenameIgnoresEmptyName() {
        let store = FolderPlaylistStore(directory: directory)
        let playlist = store.add(folder: "/m/A")
        store.rename(id: playlist.id, to: "  新名字 ")
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "新名字")
        store.rename(id: playlist.id, to: "   ")
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "新名字")
    }

    func testRemoveOnlyDropsThePlaylist() {
        let store = FolderPlaylistStore(directory: directory)
        store.remove(id: store.add(folder: "/m/A").id)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    func testTracksIncludeSubfoldersAndStayGroupedByAlbum() {
        let tracks = [track("B1", folder: "/m/Ado/Beta", number: 1), track("A1", folder: "/m/Ado/Alpha", number: 1),
                      track("A2", folder: "/m/Ado/Alpha", number: 2), track("X", folder: "/m/Adonis", number: 1)]
        XCTAssertEqual(FolderPlaylistPlanner.tracks(in: "/m/Ado", from: tracks).map(\.title), ["A1", "A2", "B1"])
    }

    func testChoicesStopBeforeLibraryRoot() {
        XCTAssertEqual(FolderPlaylistPlanner.choices(for: "/m/JPOP/Ado/Album", roots: ["/m"]),
                       ["/m/JPOP/Ado/Album", "/m/JPOP/Ado", "/m/JPOP"])
        XCTAssertTrue(FolderPlaylistPlanner.choices(for: "/m", roots: ["/m"]).isEmpty)
        XCTAssertTrue(FolderPlaylistPlanner.choices(for: "/other/Album", roots: ["/m"]).isEmpty)
    }
}
