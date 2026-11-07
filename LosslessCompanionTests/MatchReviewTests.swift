//
//  MatchReviewTests.swift
//  LosslessCompanionTests
//

import Combine
import MediaPlayer
import XCTest
@testable import LosslessCompanion

final class MatchSuggesterTests: XCTestCase {
    func testSameTitleWithDifferentLengthIsSuggested() {
        let track = makeTrack(title: "Song", seconds: 200)
        let entry = makeEntry(title: "Song", seconds: 212)
        let top = MatchSuggester(entries: [entry]).suggestions(for: track).first

        XCTAssertEqual(top?.entry.trackID, entry.trackID)
        XCTAssertEqual(top?.reasons.contains("歌名相同"), true)
    }

    func testTranslatedTitleIsFoundThroughAlbumAndLength() {
        let track = makeTrack(title: "Trenchikotomafia", artist: "Creepy Nuts", album: "Creep Show", number: 9, seconds: 180)
        let entry = makeEntry(title: "トレンチコートマフィア", artist: "Creepy Nuts", album: "Creep Show", number: 9, seconds: 181)
        let top = MatchSuggester(entries: [entry]).suggestions(for: track).first

        XCTAssertEqual(top?.entry.trackID, entry.trackID)
        XCTAssertEqual(top?.reasons, ["歌手相同", "專輯相同", "音軌相同", "長度相同"])
    }

    func testAnotherSongOnTheSameAlbumIsNotSuggested() {
        let track = makeTrack(title: "Intro", number: 1, seconds: 60)
        let entry = makeEntry(title: "Finale", number: 12, seconds: 300)
        XCTAssertTrue(MatchSuggester(entries: [entry]).suggestions(for: track).isEmpty)
    }

    func testBestCandidateComesFirst() {
        let track = makeTrack(title: "Song", artist: "Band", album: "Record", seconds: 200)
        let weak = makeEntry(0, title: "Song", artist: "Someone Else", album: "Other", seconds: 240)
        let strong = makeEntry(1, title: "Song", artist: "Band", album: "Record", seconds: 201)
        let suggestions = MatchSuggester(entries: [weak, strong]).suggestions(for: track)

        XCTAssertEqual(suggestions.first?.entry.trackID, strong.trackID)
        XCTAssertEqual(suggestions.first?.isLikely, true)
    }

    func testOtherVersionIsFlagged() {
        let track = makeTrack(title: "Song", seconds: 200)
        let live = makeEntry(title: "Song (Live)", seconds: 200)
        let top = MatchSuggester(entries: [live]).suggestions(for: track).first

        XCTAssertEqual(top?.reasons.contains("版本可能不同"), true)
    }

    func testSearchHasNoScoreThreshold() {
        let track = makeTrack(title: "Local Name", artist: "A", album: "B", seconds: 100)
        let entry = makeEntry(title: "周杰倫的歌", artist: "周杰倫", album: "Jay", seconds: 300)
        let suggester = MatchSuggester(entries: [entry])

        XCTAssertTrue(suggester.suggestions(for: track).isEmpty)
        XCTAssertEqual(suggester.search("周杰倫", for: track).map(\.entry.trackID), [entry.trackID])
        XCTAssertTrue(suggester.search("不存在", for: track).isEmpty)
    }

    func testTwoDifferentRemixesAreNotTheSameVersion() {
        let track = makeTrack(title: "ECHO (ReAdmission Remix)", artist: "Crusher-P", album: "Remixes", seconds: 200)
        let other = makeEntry(title: "ECHO (feat. Gumi) [dj-Jo Remix]", artist: "Crusher-P", album: "Remixes", seconds: 200)
        let top = MatchSuggester(entries: [other]).suggestions(for: track).first

        XCTAssertEqual(top?.isSameVersion, false)
        XCTAssertEqual(top?.isCertain, false)
    }

    func testGuestArtistDoesNotChangeTheVersion() {
        let track = makeTrack(title: "Genius", artist: "LSD", album: "LSD", seconds: 200)
        let entry = makeEntry(title: "Genius (feat. Sia, Diplo & Labrinth)", artist: "LSD", album: "LSD", seconds: 200)

        XCTAssertEqual(MatchSuggester(entries: [entry]).suggestions(for: track).first?.isCertain, true)
    }

    func testOtherVersionIsNeverCertainHoweverCloseItIs() {
        let track = makeTrack(title: "Song (Live)", artist: "Band", album: "Record", number: 3, seconds: 200)
        let studio = makeEntry(title: "Song", artist: "Band", album: "Record", number: 3, seconds: 200)
        let top = MatchSuggester(entries: [studio]).suggestions(for: track).first

        XCTAssertEqual(top?.entry.trackID, studio.trackID)
        XCTAssertEqual(top?.isCertain, false)
        XCTAssertEqual(top?.isLikely, false)
    }

    func testOnlyAnExactAgreementIsCertain() {
        let track = makeTrack(title: "Song", artist: "Band", album: "Record", seconds: 200)
        let exact = makeEntry(0, title: "Song", artist: "Band", album: "Record", seconds: 201)
        let otherAlbum = makeEntry(1, title: "Song", artist: "Band", album: "Greatest Hits", seconds: 201)

        XCTAssertEqual(MatchSuggester(entries: [exact]).suggestions(for: track).first?.isCertain, true)
        XCTAssertEqual(MatchSuggester(entries: [otherAlbum]).suggestions(for: track).first?.isCertain, false)
    }
}

final class MatchSuggestionCacheTests: XCTestCase {
    private let matched = makeTrack(title: "Song", path: "/a.flac")
    private let unknown = makeTrack(title: "Nothing Like It", artist: "Nobody", album: "Nowhere", path: "/b.flac")

    func testOnlyTracksWithCandidatesHaveScores() {
        let cache = MatchSuggestionCache()
        cache.update(entries: [makeEntry(title: "Song")], tracks: [matched, unknown])

        XCTAssertEqual(Array(cache.scores(for: [matched, unknown]).keys), ["/a.flac"])
    }

    func testSameDataKeepsTheSuggester() {
        let entries = [makeEntry(title: "Song")]
        let cache = MatchSuggestionCache()
        cache.update(entries: entries, tracks: [matched])
        let first = cache.suggester
        cache.update(entries: entries, tracks: [matched])

        XCTAssertTrue(cache.suggester === first)
    }

    func testNewMusicLibraryRecalculatesScores() {
        let cache = MatchSuggestionCache()
        cache.update(entries: [makeEntry(title: "Something Else", artist: "Nobody", album: "Nowhere", seconds: 900)], tracks: [matched])
        XCTAssertTrue(cache.scores(for: [matched]).isEmpty)

        cache.update(entries: [makeEntry(title: "Song")], tracks: [matched])

        XCTAssertEqual(cache.scores(for: [matched]).count, 1)
    }
}

final class MatchDecisionTests: XCTestCase {
    func testSongLinksToOneFile() {
        let first = makeTrack(title: "A", path: "/a.flac")
        let second = makeTrack(title: "A", path: "/b.flac")
        let entry = makeEntry(title: "A")
        var decisions = MatchDecisions()

        decisions.link(first, to: entry)
        decisions.link(second, to: entry)

        XCTAssertEqual(Array(decisions.links.keys), ["/b.flac"])
    }

    func testLocalOnlyAndLinkReplaceEachOther() {
        let track = makeTrack(title: "A", path: "/a.flac")
        var decisions = MatchDecisions()

        decisions.markLocalOnly(track.path)
        decisions.link(track, to: makeEntry(title: "A"))
        XCTAssertTrue(decisions.localOnly.isEmpty)

        decisions.markLocalOnly(track.path)
        XCTAssertTrue(decisions.links.isEmpty)

        decisions.undo(track.path)
        XCTAssertTrue(decisions.isEmpty)
    }

    func testDecisionsSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = makeTrack(title: "A", path: "/a.flac")
        let store = MatchReviewStore(directory: directory)

        store.link(track, to: makeEntry(title: "A"))
        store.markLocalOnly(makeTrack(title: "B", path: "/b.flac"))

        let reloaded = MatchReviewStore(directory: directory)
        XCTAssertEqual(reloaded.decisions, store.decisions)
        XCTAssertEqual(reloaded.decisions.links["/a.flac"]?.title, "A")
        XCTAssertEqual(reloaded.decisions.localOnly, ["/b.flac"])
    }
}

final class MatchResolverTests: XCTestCase {
    func testManualLinkConnectsWhatTheMatcherRejects() {
        let track = makeTrack(title: "Local Title", seconds: 200)
        let entry = makeEntry(title: "Music Title", seconds: 260)
        var decisions = MatchDecisions()
        XCTAssertNil(MatchResolver.resolve(tracks: [track], entries: [entry], decisions: decisions).matches[entry.trackID])

        decisions.link(track, to: entry)
        let resolved = MatchResolver.resolve(tracks: [track], entries: [entry], decisions: decisions)

        XCTAssertEqual(resolved.matches[entry.trackID]?.track, track)
        XCTAssertEqual(resolved.matches[entry.trackID]?.confidence, .manual)
        XCTAssertEqual(resolved.apple[track.path]?.trackID, entry.trackID)
    }

    func testManualLinkOverridesAutomaticMatch() {
        let automatic = makeTrack(title: "Song", path: "/auto.flac")
        let preferred = makeTrack(title: "Other Name", path: "/manual.flac")
        let entry = makeEntry(title: "Song")
        var decisions = MatchDecisions()
        decisions.link(preferred, to: entry)

        let resolved = MatchResolver.resolve(tracks: [automatic, preferred], entries: [entry], decisions: decisions)

        XCTAssertEqual(resolved.matches[entry.trackID]?.track.path, "/manual.flac")
        XCTAssertNil(resolved.apple["/auto.flac"])
    }

    func testLinkAppliesToTheSameSongWithAnotherID() {
        let track = makeTrack(title: "Local Title", seconds: 200)
        let library = makeEntry(0, title: "Music Title", seconds: 260, id: "AAAA")
        let curated = makeEntry(3, title: "Music Title", seconds: 260, id: "BBBB")
        var decisions = MatchDecisions()
        decisions.link(track, to: library)

        let resolved = MatchResolver.resolve(tracks: [track], entries: [library, curated], decisions: decisions)

        XCTAssertEqual(resolved.matches["BBBB"]?.track, track)
    }

    func testLinkToMissingFileFallsBackToAutomatic() {
        let gone = makeTrack(title: "Old", path: "/gone.flac")
        let current = makeTrack(title: "Song", path: "/here.flac")
        let entry = makeEntry(title: "Song")
        var decisions = MatchDecisions()
        decisions.link(gone, to: entry)

        let resolved = MatchResolver.resolve(tracks: [current], entries: [entry], decisions: decisions)

        XCTAssertEqual(resolved.matches[entry.trackID]?.track.path, "/here.flac")
        XCTAssertEqual(resolved.matches[entry.trackID]?.confidence, .exact)
    }

    func testFavoriteFollowsManualLink() {
        let track = makeTrack(title: "Local Title", seconds: 200)
        var entry = makeEntry(title: "Music Title", seconds: 260)
        entry.isFavorite = true
        var decisions = MatchDecisions()
        decisions.link(track, to: entry)

        XCTAssertEqual(MatchResolver.resolve(tracks: [track], entries: [entry], decisions: decisions).favorites, [track.path])
    }

    func testReviewedTracksLeaveTheUnmatchedList() {
        let linked = makeTrack(title: "A", path: "/a.flac")
        let localOnly = makeTrack(title: "B", path: "/b.flac")
        let pending = makeTrack(title: "C", path: "/c.flac")
        let entry = makeEntry(title: "Music Title", seconds: 500)
        var decisions = MatchDecisions()
        decisions.link(linked, to: entry)
        decisions.markLocalOnly(localOnly.path)

        let tracks = [linked, localOnly, pending]
        let resolved = MatchResolver.resolve(tracks: tracks, entries: [entry], decisions: decisions)
        let index = LibraryIndex.build(tracks: tracks, addedAt: [:], apple: resolved.apple, decisions: decisions)

        XCTAssertEqual(index.unmatchedTracks.map(\.path), ["/c.flac"])
        XCTAssertEqual(index.unmatchedPaths, ["/c.flac"])
        XCTAssertEqual(index.linkedTracks.map(\.path), ["/a.flac"])
        XCTAssertEqual(index.localOnlyTracks.map(\.path), ["/b.flac"])
    }
}

final class DuplicateDetectionTests: XCTestCase {
    private let kept = makeTrack(title: "Song", artist: "Band", album: "Record", rate: 96_000, bits: 24, path: "/hires/song.flac")
    private let copy = makeTrack(title: "Song", artist: "Band", album: "Record", path: "/cd/song.flac")
    private let entry = makeEntry(title: "Song", artist: "Band", album: "Record")

    private func duplicates(of track: LibraryTrack, keeping match: LibraryTrack?) -> [String: LibraryTrack] {
        let suggester = MatchSuggester(entries: [entry])
        let score = suggester.bestScore(for: track).map { [track.path: $0] } ?? [:]
        let matches = match.map { [entry.trackID: LocalMatch(track: $0, confidence: .exact)] } ?? [:]
        return MatchResolver.duplicates(in: [track], scores: score, suggester: suggester, matches: matches)
    }

    func testSecondCopyOfAMatchedSongIsADuplicate() {
        XCTAssertEqual(duplicates(of: copy, keeping: kept), [copy.path: kept])
    }

    func testSongWithoutAFileIsNotADuplicate() {
        XCTAssertTrue(duplicates(of: copy, keeping: nil).isEmpty)
    }

    func testTheMatchedFileItselfIsNotADuplicate() {
        XCTAssertTrue(duplicates(of: kept, keeping: kept).isEmpty)
    }

    func testDifferentVersionIsNotADuplicate() {
        let live = makeTrack(title: "Song (Live)", artist: "Band", album: "Record", path: "/live/song.flac")
        XCTAssertTrue(duplicates(of: live, keeping: kept).isEmpty)
    }

    func testBulkLocalOnlyWritesOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MatchReviewStore(directory: directory)
        var changes = 0
        let observer = store.$decisions.dropFirst().sink { _ in changes += 1 }

        store.markLocalOnly([kept, copy])

        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.decisions.localOnly, [kept.path, copy.path])
        observer.cancel()
    }
}

final class FormatFilterTests: XCTestCase {
    private let cd = makeTrack(title: "CD", rate: 44_100, bits: 16, path: "/a/cd.flac")
    private let hiRes = makeTrack(title: "Hi", rate: 96_000, bits: 24, path: "/a/hi.WAV")

    func testGroups() {
        XCTAssertTrue(FormatFilter.all.matches(cd))
        XCTAssertTrue(FormatFilter(tiers: [.hiRes]).matches(hiRes))
        XCTAssertFalse(FormatFilter(tiers: [.hiRes]).matches(cd))
        XCTAssertTrue(FormatFilter(tiers: [.standard]).matches(cd))
        XCTAssertFalse(FormatFilter(tiers: [.standard]).matches(hiRes))
    }

    func testExactSpecs() {
        XCTAssertTrue(FormatFilter(sampleRates: [96_000]).matches(hiRes))
        XCTAssertFalse(FormatFilter(sampleRates: [96_000]).matches(cd))
        XCTAssertTrue(FormatFilter(bitDepths: [16]).matches(cd))
        XCTAssertFalse(FormatFilter(bitDepths: [16]).matches(hiRes))
    }

    func testFileTypeIgnoresCase() {
        XCTAssertTrue(FormatFilter(fileTypes: ["WAV"]).matches(hiRes))
        XCTAssertTrue(FormatFilter(fileTypes: ["FLAC"]).matches(cd))
        XCTAssertFalse(FormatFilter(fileTypes: ["FLAC"]).matches(hiRes))
    }

    func testAnySelectionInACategoryIsEnough() {
        let filter = FormatFilter(sampleRates: [44_100, 96_000])

        XCTAssertTrue(filter.matches(cd))
        XCTAssertTrue(filter.matches(hiRes))
        XCTAssertFalse(filter.matches(makeTrack(title: "Other", rate: 192_000, bits: 24)))
    }

    func testEveryCategoryMustMatch() {
        XCTAssertTrue(FormatFilter(sampleRates: [96_000], bitDepths: [24], fileTypes: ["WAV"]).matches(hiRes))
        XCTAssertFalse(FormatFilter(sampleRates: [96_000], bitDepths: [16]).matches(hiRes))
        XCTAssertFalse(FormatFilter(sampleRates: [96_000], fileTypes: ["FLAC"]).matches(hiRes))
    }

    func testAlbumMatchesWhenAnyTrackDoes() {
        let album = AlbumGroup(id: "a", title: "Mixed", artist: "A", tracks: [cd, hiRes], addedAt: 0)

        XCTAssertTrue(FormatFilter(tiers: [.hiRes]).matches(album))
        XCTAssertFalse(FormatFilter(sampleRates: [192_000]).matches(album))
    }

    func testAlbumNeedsOneTrackThatMatchesEveryCategory() {
        let album = AlbumGroup(id: "a", title: "Mixed", artist: "A", tracks: [cd, hiRes], addedAt: 0)

        // 44.1 kHz 和 24-bit 各有一首，但沒有一首同時符合
        XCTAssertFalse(FormatFilter(sampleRates: [44_100], bitDepths: [24]).matches(album))
        XCTAssertTrue(FormatFilter(sampleRates: [96_000], bitDepths: [24]).matches(album))
    }

    func testTitlesFollowTheMenuOrder() {
        let filter = FormatFilter(tiers: [.hiRes], sampleRates: [96_000, 44_100], bitDepths: [24], fileTypes: ["WAV", "FLAC"])

        XCTAssertEqual(filter.titles, ["Hi-Res", Format.sampleRate(44_100), Format.sampleRate(96_000), "24-bit", "FLAC", "WAV"])
    }
}

final class OutputOptionsTests: XCTestCase {
    func testDefaultKeepsTheOriginalBehavior() {
        let options = OutputOptions()
        XCTAssertEqual(options.lockInSeconds, 0.25)
        XCTAssertFalse(options.forcesMaxVolume)
        XCTAssertTrue(OutputOptions.lockInChoices.contains(options.lockInSeconds))
    }

    func testRoundTrip() throws {
        let options = OutputOptions(lockInSeconds: 2, forcesMaxVolume: true)
        let data = try JSONEncoder().encode(["uid": options])

        XCTAssertEqual(try JSONDecoder().decode([String: OutputOptions].self, from: data)["uid"], options)
    }

    func testVolumeText() {
        XCTAssertEqual(Format.deviceVolume(1), "100%")
        XCTAssertEqual(Format.deviceVolume(0.625), "63%")
        XCTAssertEqual(Format.deviceVolume(nil), "裝置沒有音量控制")
    }
}

final class NowPlayingSnapshotTests: XCTestCase {
    private let item = localItem("Song", seconds: 240)

    func testPlayingReportsRateOne() {
        let info = NowPlayingSnapshot.info(item: item, status: .playing, elapsed: 12)

        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Song")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, 240)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval, 12)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    }

    func testPausedStopsTheSystemClock() {
        XCTAssertEqual(NowPlayingSnapshot.info(item: item, status: .paused, elapsed: 12)[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    func testStates() {
        XCTAssertEqual(NowPlayingSnapshot.playbackState(for: .idle), .stopped)
        XCTAssertEqual(NowPlayingSnapshot.playbackState(for: .paused), .paused)
        XCTAssertEqual(NowPlayingSnapshot.playbackState(for: .preparing), .playing)
        XCTAssertEqual(NowPlayingSnapshot.playbackState(for: .playing), .playing)
    }
}

final class AppearanceModeTests: XCTestCase {
    func testAppearanceFollowsTheChoice() {
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testStoredValueRoundTrips() {
        for mode in AppearanceMode.allCases {
            XCTAssertEqual(AppearanceMode(rawValue: mode.rawValue), mode)
        }
    }
}
