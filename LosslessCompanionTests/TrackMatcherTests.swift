//
//  TrackMatcherTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

final class TrackMatcherTests: XCTestCase {
    func testExactMatchNeedsTitleArtistAlbumAndDuration() {
        let track = makeTrack(title: "夜に駆ける", artist: "YOASOBI", album: "THE BOOK", seconds: 261)
        let matcher = TrackMatcher(tracks: [track])

        let match = matcher.match(makeEntry(title: "夜に駆ける", artist: "YOASOBI", album: "THE BOOK", seconds: 261.5))

        XCTAssertEqual(match?.track, track)
        XCTAssertEqual(match?.confidence, .exact)
    }

    func testTrackNumberInsideTitleIsIgnored() {
        let track = makeTrack(title: "01. 不知反省", artist: "老王乐队", album: "吾日三省吾身 [台湾版]", seconds: 106)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertNotNil(matcher.match(makeEntry(title: "不知反省", artist: "老王樂隊", album: "吾日三省吾身", seconds: 106)))
    }

    func testTraditionalAndSimplifiedTitlesAreEquivalent() {
        let track = makeTrack(title: "後來", artist: "劉若英", album: "我等你", seconds: 300)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertNotNil(matcher.match(makeEntry(title: "后来", artist: "刘若英", album: "我等你", seconds: 300)))
    }

    func testLiveVersionIsNotMatchedToStudioRecording() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song (Live)", seconds: 200)))
        XCTAssertNil(matcher.match(makeEntry(title: "Song - Live at Budokan", seconds: 200)))
    }

    func testRemasterAndRemixAreSeparateVersions() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song (2011 Remaster)", seconds: 200)))
        XCTAssertNil(matcher.match(makeEntry(title: "Song (Club Remix)", seconds: 200)))
    }

    func testAlternateMixIsSeparateVersion() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song (Eight Mix) [feat. Guest]", seconds: 200)))
    }

    func testTrackFromLiveAlbumIsNotTheStudioRecording() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", album: "2024 World Tour", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song", album: "Studio Album", seconds: 200)))
    }

    func testInstrumentalIsNotTheVocalVersion() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song (Instrumental)", seconds: 200)))
        XCTAssertNil(matcher.match(makeEntry(title: "Song (伴奏)", seconds: 200)))
    }

    func testSameVersionTagsMatch() {
        let track = makeTrack(title: "Song (Live)", seconds: 200)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertEqual(matcher.match(makeEntry(title: "Song [Live]", seconds: 200))?.track, track)
    }

    func testFeaturedArtistInTitleDoesNotBlockMatch() {
        let track = makeTrack(title: "Song", artist: "Main", seconds: 200)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertEqual(matcher.match(makeEntry(title: "Song (feat. Guest)", artist: "Main", seconds: 200))?.track, track)
    }

    func testCoverByAnotherArtistIsRejected() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", artist: "Original", album: "One", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song", artist: "Cover Band", album: "Two", seconds: 200)))
    }

    func testDurationOutsideToleranceIsRejected() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song", seconds: 205)))
        XCTAssertNotNil(matcher.match(makeEntry(title: "Song", seconds: 202)))
    }

    func testArtistWrittenDifferentlyMatchesThroughAlbumSlot() {
        let track = makeTrack(title: "Song", artist: "ヨルシカ", album: "Album Name", number: 3, seconds: 200)
        let matcher = TrackMatcher(tracks: [track])

        let match = matcher.match(makeEntry(title: "Song", artist: "Yorushika", album: "Album Name", number: 3, seconds: 200.5))

        XCTAssertEqual(match?.confidence, .strong)
    }

    func testTranslatedArtistMatchesThroughAlbumAndDuration() {
        let track = makeTrack(title: "Francesca da Rimini, Op. 32", artist: "Antonio Pappano", album: "Tchaikovsky: Overtures", number: 4, seconds: 1400)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertNotNil(matcher.match(makeEntry(title: "Francesca da Rimini, Op. 32", artist: "安東尼奧・帕帕諾",
                                                album: "Tchaikovsky: Overtures & Fantasies", number: 2, seconds: 1400.3)))
    }

    func testDifferentArtistInSameAlbumNeedsCloseDuration() {
        let matcher = TrackMatcher(tracks: [makeTrack(title: "Song", artist: "ヨルシカ", album: "Album Name", seconds: 200)])

        XCTAssertNil(matcher.match(makeEntry(title: "Song", artist: "Yorushika", album: "Album Name", seconds: 202)))
    }

    func testSameReleaseAllowsLargerDurationDifference() {
        let track = makeTrack(title: "Song", artist: "Main", album: "Album Name", seconds: 200)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertEqual(matcher.match(makeEntry(title: "Song", artist: "Main", album: "Album Name", seconds: 203.5))?.confidence, .exact)
        XCTAssertNil(matcher.match(makeEntry(title: "Song", artist: "Main", album: "Other Record", seconds: 203.5)))
    }

    func testArtistListsOverlap() {
        let track = makeTrack(title: "Song", artist: "Alpha, Beta", seconds: 200)
        let matcher = TrackMatcher(tracks: [track])

        XCTAssertEqual(matcher.match(makeEntry(title: "Song", artist: "Beta & Gamma", seconds: 200))?.track, track)
    }

    func testPrefersSameAlbumOverHigherResolutionElsewhere() {
        let compilation = makeTrack(title: "Song", album: "Best Of", seconds: 200, rate: 96_000, bits: 24)
        let original = makeTrack(title: "Song", album: "Album", seconds: 200)
        let matcher = TrackMatcher(tracks: [compilation, original])

        XCTAssertEqual(matcher.match(makeEntry(title: "Song", album: "Album", seconds: 200))?.track, original)
    }

    func testPrefersHigherResolutionAmongEqualCandidates() {
        let cd = makeTrack(title: "Song", seconds: 200)
        let hiRes = makeTrack(title: "Song", seconds: 200, rate: 96_000, bits: 24, path: "/hi/song.flac")
        let matcher = TrackMatcher(tracks: [cd, hiRes])

        XCTAssertEqual(matcher.match(makeEntry(title: "Song", seconds: 200))?.track, hiRes)
    }

    func testSingleAndEPSuffixesAreIgnored() {
        XCTAssertEqual(TrackMatcher.albumKey("Thing - Single"), TrackMatcher.albumKey("Thing"))
        XCTAssertEqual(TrackMatcher.albumKey("Thing - EP"), TrackMatcher.albumKey("Thing"))
        XCTAssertEqual(TrackMatcher.albumKey("Thing (Deluxe Edition)"), TrackMatcher.albumKey("Thing"))
    }

    func testVersionedLanguageTitlesStayDistinct() {
        let fingerprint = TitleFingerprint(title: "Song (Japanese Ver.)")

        XCTAssertEqual(fingerprint.core, "song")
        XCTAssertFalse(fingerprint.versions.isEmpty)
    }

    func testSymbolOnlyTitlesStillHaveKey() {
        XCTAssertFalse(TitleFingerprint(title: "(  )").core.isEmpty && TitleFingerprint(title: "1").core.isEmpty)
    }
}

final class MusicPlaylistParserTests: XCTestCase {
    private let us = MusicPlaylistParser.unitSeparator
    private let rs = MusicPlaylistParser.recordSeparator
    private let gs = MusicPlaylistParser.groupSeparator

    private func columns(_ values: [[String]]) -> String {
        values.map { $0.joined(separator: us) }.joined(separator: rs)
    }

    private var header: String { ["AB", "My | List", "false", "user", "2"].joined(separator: us) }

    private var body: [[String]] {
        [["01", "02"], ["歌, 一", "Two"], ["A", "missing value"], ["", ""], ["X", "Y"],
         ["262.169006347656", "1.2E+2"], ["3", "1"], ["1", "1"], ["2020", "0"], ["subscription", "uploaded"],
         ["Rock", "missing value"], ["Bach", ""], ["true", "false"]]
    }

    func testParsesPlaylistInOrder() throws {
        let parsed = MusicPlaylistParser.parse(header + rs + columns(body))

        let playlist = try XCTUnwrap(parsed.playlists.first)
        XCTAssertEqual(playlist.name, "My | List")
        XCTAssertEqual(playlist.entries.map(\.trackID), ["01", "02"])
        XCTAssertEqual(playlist.entries[0].title, "歌, 一")
        XCTAssertEqual(playlist.entries[0].duration, 262.169, accuracy: 0.001)
        XCTAssertEqual(playlist.entries[1].duration, 120, accuracy: 0.001)
        XCTAssertEqual(playlist.entries[1].artist, "")
    }

    func testReadsGenreComposerAndFavorite() throws {
        let entries = try XCTUnwrap(MusicPlaylistParser.parse(header + rs + columns(body)).playlists.first).entries

        XCTAssertEqual(entries[0].genre, "Rock")
        XCTAssertEqual(entries[0].composer, "Bach")
        XCTAssertEqual(entries[0].isFavorite, true)
        XCTAssertEqual(entries[1].genre, "")
        XCTAssertEqual(entries[1].isFavorite, false)
    }

    func testLibraryGroupIsSeparateAndSharesDatesWithPlaylists() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let libraryHeader = ["LL", "音樂", "false", "library", "1"].joined(separator: us)
        let library = body.map { [$0[0]] } + [["-500"]]

        let parsed = MusicPlaylistParser.parse(header + rs + columns(body) + gs + libraryHeader + rs + columns(library), now: now)

        XCTAssertEqual(parsed.playlists.count, 1, "the library never appears as a playlist")
        XCTAssertEqual(parsed.library.first?.dateAdded, 999_500)
        XCTAssertEqual(parsed.playlists[0].entries[0].dateAdded, 999_500)
        XCTAssertNil(parsed.playlists[0].entries[1].dateAdded)
    }

    func testMisalignedColumnsDropThePlaylistInsteadOfShiftingFields() {
        var broken = body
        broken[2] = ["A"]

        XCTAssertTrue(MusicPlaylistParser.parse(header + rs + columns(broken)).playlists.isEmpty)
    }

    func testEmptyPlaylistIsKept() {
        let text = ["CD", "Empty", "false", "subscription", "0"].joined(separator: us)

        let parsed = MusicPlaylistParser.parse(header + rs + columns(body) + gs + text).playlists

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[1].isSubscription, true)
        XCTAssertTrue(parsed[1].entries.isEmpty)
    }

    func testCommaDecimalLocale() {
        var localized = body
        localized[5] = ["262,5", "120"]

        XCTAssertEqual(MusicPlaylistParser.parse(header + rs + columns(localized)).playlists.first?.entries[0].duration, 262.5)
    }

    func testOldCacheWithoutNewFieldsStillDecodes() throws {
        let json = #"[{"position":0,"trackID":"AB","title":"T","artist":"A","albumArtist":"","album":"X","duration":1,"trackNumber":1,"discNumber":1,"year":0,"cloudStatus":"subscription"}]"#

        let decoded = try JSONDecoder().decode([MusicPlaylistEntry].self, from: Data(json.utf8))

        XCTAssertNil(decoded[0].genre)
    }

    func testSameSongTwiceHasDistinctIDs() {
        let first = makeEntry(0, title: "A", id: "AA")
        let second = makeEntry(1, title: "A", id: "AA")

        XCTAssertNotEqual(first.id, second.id)
    }

    func testUnavailableTracksAreNotStreamable() {
        XCTAssertFalse(makeEntry(title: "A", cloud: "no longer available").isStreamable)
        XCTAssertTrue(makeEntry(title: "A", cloud: "uploaded").isStreamable)
    }
}

final class MusicScriptsTests: XCTestCase {
    func testIdentifiersCannotInjectScript() {
        XCTAssertThrowsError(try MusicScripts.play(playlistID: "AB\" & quit", trackID: "01"))
        XCTAssertThrowsError(try MusicScripts.artwork(playlistID: "AB", trackID: ""))
        XCTAssertNoThrow(try MusicScripts.play(playlistID: "06B95A881AFC9A86", trackID: "06b95a881afc9a86"))
    }

    func testPersistentIDFromNotificationMatchesScriptFormat() {
        XCTAssertEqual(MusicScripts.hexIdentifier(from: NSNumber(value: Int64(bitPattern: 0x06B9_5A88_1AFC_9A86))), "06B95A881AFC9A86")
        XCTAssertEqual(MusicScripts.hexIdentifier(from: NSNumber(value: Int64(bitPattern: 0xF6B9_5A88_1AFC_9A86))), "F6B95A881AFC9A86")
    }

    func testSeekIsNeverNegative() {
        XCTAssertTrue(MusicScripts.seek(to: -3).hasSuffix("0.000"))
    }

    func testVolumeIsClamped() {
        XCTAssertTrue(MusicScripts.setVolume(180).hasSuffix("100"))
    }
}

final class LibraryBrowserTests: XCTestCase {
    func testDiscFoldersBelongToOneAlbum() {
        let first = makeTrack(title: "A", album: "Set", number: 1, path: "/m/Set/Disc 1/1.flac")
        let second = makeTrack(title: "B", album: "Set", number: 1, path: "/m/Set/CD2/1.flac")

        XCTAssertEqual(LibraryBrowser.albums(from: [first, second], addedAt: [:]).count, 1)
    }

    func testAlbumArtistIsTheMostCommon() {
        let tracks = [makeTrack(title: "A", artist: "X", number: 1, path: "/m/a/1.flac"),
                      makeTrack(title: "B", artist: "X", number: 2, path: "/m/a/2.flac"),
                      makeTrack(title: "C", artist: "Y", number: 3, path: "/m/a/3.flac")]

        XCTAssertEqual(LibraryBrowser.albums(from: tracks, addedAt: [:]).first?.artist, "X")
    }

    func testBestFormatUsesHighestResolution() {
        let tracks = [makeTrack(title: "A", number: 1, path: "/m/a/1.flac"),
                      makeTrack(title: "B", number: 2, rate: 96_000, bits: 24, path: "/m/a/2.flac")]

        XCTAssertEqual(LibraryBrowser.albums(from: tracks, addedAt: [:]).first?.bestFormat.bits, 24)
    }
}

/// 用真實資料檢查比對品質；只有設定 LC_RAW_PLAYLISTS 時才執行，資料不會進專案
final class RealDataReportTests: XCTestCase {
    func testReportMatchesAgainstRealLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawPath = environment["LC_RAW_PLAYLISTS"], let libraryPath = environment["LC_LIBRARY_CACHE"] else {
            throw XCTSkip("real data not provided")
        }
        let raw = try String(contentsOfFile: rawPath, encoding: .utf8)
        let snapshot = MusicPlaylistParser.parse(raw.trimmingCharacters(in: .newlines))
        let playlists = snapshot.playlists
        let library = LocalLibrary(folders: [], cacheURL: URL(fileURLWithPath: libraryPath))
        library.publishNow()
        let expectation = expectation(description: "publish")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 5)

        let matcher = TrackMatcher(tracks: library.tracks)
        var lines = ["library=\(library.tracks.count)"]
        var seen = Set<String>()
        var exact = 0, strong = 0, none = 0
        var samples = [String]()
        let start = Date()
        for playlist in playlists {
            var matched = 0
            for entry in playlist.entries {
                let result = matcher.match(entry)
                if result != nil { matched += 1 }
                guard seen.insert(entry.trackID).inserted else { continue }
                switch result?.confidence {
                case .exact, .manual: exact += 1
                case .strong:
                    strong += 1
                    if let result { samples.append("STRONG\t\(entry.title)\t\(entry.artist)\t\(entry.album)\t=>\t\(result.track.title)\t\(result.track.artist)\t\(result.track.album)") }
                case nil: none += 1
                }
            }
            lines.append("playlist \(playlist.entries.count) matched \(matched)")
        }
        lines.append("unique=\(seen.count) exact=\(exact) strong=\(strong) none=\(none) seconds=\(Date().timeIntervalSince(start))")
        try (lines + samples).joined(separator: "\n").write(toFile: rawPath + ".report", atomically: true, encoding: .utf8)
    }
}
