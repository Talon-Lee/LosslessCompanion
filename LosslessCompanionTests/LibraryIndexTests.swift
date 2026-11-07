//
//  LibraryIndexTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

private func tagged(_ title: String, artist: String = "Artist", album: String = "Album", number: Int = 1,
                    genre: String? = nil, albumArtist: String? = nil, composer: String? = nil, year: Int? = nil,
                    path: String) -> LibraryTrack {
    var track = makeTrack(title: title, artist: artist, album: album, number: number, path: path)
    track.genre = genre
    track.albumArtist = albumArtist
    track.composer = composer
    track.year = year
    return track
}

private func entry(_ title: String, genre: String? = nil, composer: String? = nil, albumArtist: String = "") -> MusicPlaylistEntry {
    MusicPlaylistEntry(position: 0, trackID: title, title: title, artist: "Artist", albumArtist: albumArtist, album: "Album",
                       duration: 200, trackNumber: 1, discNumber: 1, year: 2020, cloudStatus: "subscription",
                       genre: genre, composer: composer)
}

final class GenreNameTests: XCTestCase {
    func testMessyTagsBecomeAppleMusicNames() {
        for tag in ["JPOP", "jpop", "J-POP/General", "ポップス", "日本流行樂"] {
            XCTAssertEqual(GenreName.canonical(tag), "J-Pop", tag)
        }
        XCTAssertEqual(GenreName.canonical("Soundtracks"), "Soundtrack")
        XCTAssertEqual(GenreName.canonical("Alternative & Indie"), "Alternative")
        XCTAssertEqual(GenreName.canonical("Rap/Hip Hop"), "Hip-Hop/Rap")
        XCTAssertEqual(GenreName.canonical("Klassik"), "Classical")
    }

    func testListsAndSubGenresUseTheMainGenre() {
        XCTAssertEqual(GenreName.canonical("Alternative Metal;Pop/Rock;Heavy Metal"), "Alternative Metal")
        XCTAssertEqual(GenreName.canonical("Classical/Chamber Music"), "Classical")
        XCTAssertEqual(GenreName.canonical("J-POP/General"), "J-Pop")
        XCTAssertEqual(GenreName.canonical("Alternative Rock/General"), "Alternative")
    }

    func testMeaninglessTagsAreIgnored() {
        XCTAssertNil(GenreName.canonical(" "))
        XCTAssertNil(GenreName.canonical("Miscellaneous"))
        XCTAssertNil(GenreName.canonical(nil))
    }

    func testUnknownTagIsKept() {
        XCTAssertEqual(GenreName.canonical("Shoegaze"), "Shoegaze")
    }
}

final class LibraryIndexTests: XCTestCase {
    func testMusicGenreWinsAndCoversTheWholeAlbum() {
        let first = tagged("A", number: 1, genre: "Pop", path: "/m/a/1.flac")
        let second = tagged("B", number: 2, genre: "Other Thing", path: "/m/a/2.flac")

        let index = LibraryIndex.build(tracks: [first, second], addedAt: [:], apple: [first.path: entry("A", genre: "Mandopop")])

        XCTAssertEqual(index.albums.first?.genre, "Mandopop")
        XCTAssertEqual(index.genres.map(\.name), ["Mandopop"])
    }

    func testFileTagIsUsedWithoutAMatch() {
        let track = tagged("A", genre: "JPOP", path: "/m/a/1.flac")

        XCTAssertEqual(LibraryIndex.build(tracks: [track], addedAt: [:], apple: [:]).albums.first?.genre, "J-Pop")
    }

    func testUnclassifiedAlbumsSortLast() {
        let tagged1 = tagged("A", genre: "Rock", path: "/m/a/1.flac")
        let plain = tagged("B", path: "/m/b/1.flac")
        let zed = tagged("C", genre: "Zydeco", path: "/m/c/1.flac")

        let names = LibraryIndex.build(tracks: [tagged1, plain, zed], addedAt: [:], apple: [:]).genres.map(\.name)

        XCTAssertEqual(names, ["Rock", "Zydeco", GenreName.unclassified])
    }

    func testUnmatchedTracksAndAlbums() {
        let matched = tagged("A", number: 1, path: "/m/a/1.flac")
        let sibling = tagged("B", number: 2, path: "/m/a/2.flac")
        let other = tagged("C", album: "Other", path: "/m/b/1.flac")

        let index = LibraryIndex.build(tracks: [matched, sibling, other], addedAt: [:], apple: [matched.path: entry("A")])

        XCTAssertEqual(index.unmatchedTracks.map(\.title).sorted(), ["B", "C"])
        XCTAssertEqual(index.unmatchedAlbums.count, 2, "a partly matched album still lists its unmatched tracks")
    }

    func testAlbumArtistComesBeforeTrackArtist() {
        let first = tagged("A", artist: "Guest One", number: 1, albumArtist: "Main", path: "/m/a/1.flac")
        let second = tagged("B", artist: "Guest Two", number: 2, albumArtist: "Main", path: "/m/a/2.flac")

        XCTAssertEqual(LibraryIndex.build(tracks: [first, second], addedAt: [:], apple: [:]).artists.map(\.name), ["Main"])
    }

    func testVariousArtistsAlbumIsACompilation() {
        let track = tagged("A", albumArtist: "Various Artists", path: "/m/a/1.flac")

        let index = LibraryIndex.build(tracks: [track], addedAt: [:], apple: [:])

        XCTAssertEqual(index.compilations.count, 1)
        XCTAssertTrue(index.artists.isEmpty, "compilations stay out of the artist list")
    }

    func testManyArtistsWithoutAlbumArtistIsACompilation() {
        let tracks = (1...4).map { tagged("T\($0)", artist: "Artist \($0)", number: $0, path: "/m/a/\($0).flac") }

        XCTAssertEqual(LibraryIndex.build(tracks: tracks, addedAt: [:], apple: [:]).compilations.first?.artist, "群星")
    }

    func testComposersIncludeMusicDataAndSplitLists() {
        let first = tagged("A", number: 1, composer: "Bach; Handel", path: "/m/a/1.flac")
        let second = tagged("B", album: "Other", number: 1, path: "/m/b/1.flac")

        let index = LibraryIndex.build(tracks: [first, second], addedAt: [:], apple: [second.path: entry("B", composer: "Bach")])

        XCTAssertEqual(index.composers.map(\.name), ["Bach", "Handel"])
        XCTAssertEqual(index.composers.first?.albums.count, 2)
    }

    func testRecentAlbumsAreNewestFirst() {
        let old = tagged("A", path: "/m/a/1.flac")
        let new = tagged("B", path: "/m/b/1.flac")

        let index = LibraryIndex.build(tracks: [old, new], addedAt: [old.path: 10, new.path: 20], apple: [:])

        XCTAssertEqual(index.recent.first?.representative, new)
    }
}

final class TrackSorterTests: XCTestCase {
    private func item(_ title: String, artist: String = "A", album: String = "X", year: Int = 2000, seconds: Double = 100,
                      added: Double = 0, disc: Int = 1, number: Int = 1) -> TrackSortFields {
        TrackSortFields(title: title, artist: artist, album: album, genre: "", year: year, duration: seconds,
                        dateAdded: added, discNumber: disc, trackNumber: number)
    }

    private func sorted(_ items: [TrackSortFields], _ sort: TrackSort) -> [String] {
        TrackSorter.sorted(items, by: sort) { $0 }.map(\.title)
    }

    func testOriginalKeepsMusicOrder() {
        let items = [item("b"), item("a")]

        XCTAssertEqual(sorted(items, .original), ["b", "a"])
        XCTAssertEqual(sorted(items, TrackSort(key: .original, ascending: false)), ["a", "b"])
    }

    func testTitleBothDirections() {
        let items = [item("b"), item("c"), item("a")]

        XCTAssertEqual(sorted(items, TrackSort(key: .title, ascending: true)), ["a", "b", "c"])
        XCTAssertEqual(sorted(items, TrackSort(key: .title, ascending: false)), ["c", "b", "a"])
    }

    func testNumbersInTitlesSortNaturally() {
        XCTAssertEqual(sorted([item("Track 10"), item("Track 2")], TrackSort(key: .title, ascending: true)), ["Track 2", "Track 10"])
    }

    func testArtistThenAlbumThenTrackNumber() {
        let items = [item("3", artist: "B", album: "X", number: 1),
                     item("2", artist: "A", album: "Y", number: 1),
                     item("1b", artist: "A", album: "X", number: 2),
                     item("1a", artist: "A", album: "X", number: 1)]

        XCTAssertEqual(sorted(items, TrackSort(key: .artist, ascending: true)), ["1a", "1b", "2", "3"])
    }

    func testDescendingArtistKeepsAlbumsInOrder() {
        let items = [item("a1", artist: "A", number: 1), item("b2", artist: "B", number: 2), item("b1", artist: "B", number: 1)]

        XCTAssertEqual(sorted(items, TrackSort(key: .artist, ascending: false)), ["b1", "b2", "a1"])
    }

    func testMissingValuesStayLastInBothDirections() {
        let items = [item("none", year: 0), item("old", year: 1990), item("new", year: 2020)]

        XCTAssertEqual(sorted(items, TrackSort(key: .year, ascending: true)), ["old", "new", "none"])
        XCTAssertEqual(sorted(items, TrackSort(key: .year, ascending: false)), ["new", "old", "none"])
    }

    func testTappingHeader() {
        let start = TrackSort.original

        let byArtist = start.tapped(.artist)
        XCTAssertEqual(byArtist, TrackSort(key: .artist, ascending: true))
        XCTAssertEqual(byArtist.tapped(.artist), TrackSort(key: .artist, ascending: false))
        XCTAssertEqual(start.tapped(.dateAdded), TrackSort(key: .dateAdded, ascending: false), "newest first by default")
    }

    func testStorageRoundTrip() {
        let sort = TrackSort(key: .album, ascending: false)

        XCTAssertEqual(TrackSort(storage: sort.storage), sort)
        XCTAssertNil(TrackSort(storage: "nonsense"))
    }

    func testQueueFollowsSortedOrder() {
        let entries = [makeEntry(0, title: "b"), makeEntry(1, title: "a")]
        let playlist = MusicPlaylist(id: "AA", name: "P", isSmart: false, isSubscription: false, entries: entries)
        let sortedEntries = TrackSorter.sorted(entries, by: TrackSort(key: .title, ascending: true), fields: \.sortFields)

        let built = QueueBuilder.items(for: playlist, entries: sortedEntries, startingAt: entries[0], preference: .appleMusicOnly) { _ in nil }

        XCTAssertEqual(built.items.map(\.title), ["a", "b"])
        XCTAssertEqual(built.index, 1)
    }

    func testAlbumSortByYearIsNewestFirst() {
        let old = AlbumGroup(id: "1", title: "Old", artist: "A", tracks: [], addedAt: 0, year: 1990)
        let new = AlbumGroup(id: "2", title: "New", artist: "A", tracks: [], addedAt: 0, year: 2020)

        XCTAssertEqual(AlbumSortKey.year.sorted([old, new]).map(\.title), ["New", "Old"])
    }
}

final class TagRefreshTests: XCTestCase {
    func testOldIndexEntriesAreRefreshedWithoutReinspectingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.wav")
        var data = Data("RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + 4).littleEndian, Array.init))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(44_100).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(176_400).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(4).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian, Array.init))
        data.append(contentsOf: Data("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian, Array.init))
        data.append(contentsOf: [0, 0, 0, 0])
        try data.write(to: file)

        var track = try LibraryInspector.inspect(url: file)
        XCTAssertEqual(track.tagVersion, TrackMetadata.version)

        track.tagVersion = nil
        let refreshed = track.updating(with: TrackMetadata.tags(for: file))
        XCTAssertEqual(refreshed.tagVersion, TrackMetadata.version)
        XCTAssertEqual(refreshed.frameCount, track.frameCount)
    }
}

final class MusicRecentsTests: XCTestCase {
    private func added(_ title: String, album: String = "Album", artist: String = "Artist", albumArtist: String = "",
                       number: Int = 1, disc: Int = 1, at date: Double? = nil, position: Int = 0) -> MusicPlaylistEntry {
        MusicPlaylistEntry(position: position, trackID: title, title: title, artist: artist, albumArtist: albumArtist, album: album,
                           duration: 200, trackNumber: number, discNumber: disc, year: 2020, cloudStatus: "subscription",
                           dateAdded: date)
    }

    func testAlbumsAreOrderedByNewestTrack() {
        let albums = MusicRecents.albums(from: [added("old", album: "Old", at: 100),
                                                added("new", album: "New", at: 300),
                                                added("middle", album: "Middle", at: 200)])

        XCTAssertEqual(albums.map(\.title), ["New", "Middle", "Old"])
    }

    func testAddingOneMoreTrackMovesTheAlbumToTheFront() {
        let albums = MusicRecents.albums(from: [added("a1", album: "A", at: 100),
                                                added("b1", album: "B", at: 200),
                                                added("a2", album: "A", number: 2, at: 300)])

        XCTAssertEqual(albums.map(\.title), ["A", "B"])
        XCTAssertEqual(albums[0].addedAt, 300)
        XCTAssertEqual(albums[0].playlist.entries.map(\.title), ["a1", "a2"])
    }

    func testTracksFollowDiscAndTrackOrder() {
        let albums = MusicRecents.albums(from: [added("d2", number: 1, disc: 2, at: 1),
                                                added("t2", number: 2, at: 1),
                                                added("t1", number: 1, at: 1)])

        XCTAssertEqual(albums[0].playlist.entries.map(\.title), ["t1", "t2", "d2"])
    }

    func testSameAlbumNameByDifferentArtistsStaysSeparate() {
        let albums = MusicRecents.albums(from: [added("a", album: "Greatest Hits", artist: "One", at: 1),
                                                added("b", album: "Greatest Hits", artist: "Two", at: 2)])

        XCTAssertEqual(albums.map(\.artist), ["Two", "One"])
    }

    func testAlbumArtistKeepsGuestTracksTogether() {
        let albums = MusicRecents.albums(from: [added("a", artist: "Main", albumArtist: "Main", at: 1),
                                                added("b", artist: "Main & Guest", albumArtist: "Main", at: 2)])

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].artist, "Main")
    }

    func testTracksWithoutAlbumAreSeparateItems() {
        let albums = MusicRecents.albums(from: [added("Loose One", album: "", at: 2), added("Loose Two", album: "", at: 1)])

        XCTAssertEqual(albums.map(\.title), ["Loose One", "Loose Two"])
    }

    func testLimitKeepsTheNewest() {
        let albums = MusicRecents.albums(from: [added("old", album: "Old", at: 1), added("new", album: "New", at: 2)], limit: 1)

        XCTAssertEqual(albums.map(\.title), ["New"])
    }

    func testEveryTrackFindsItsAlbumBeyondTheRecentLimit() {
        let library = [added("old", album: "Old", at: 1), added("new", album: "New", at: 2), added("new2", album: "New", number: 2, at: 2)]
        let byTrack = MusicRecents.albumsByTrack(MusicRecents.allAlbums(from: library))

        XCTAssertEqual(byTrack["old"]?.title, "Old")
        XCTAssertEqual(byTrack["new2"]?.title, "New")
        XCTAssertEqual(byTrack["new2"]?.playlist.entries.map(\.title), ["new", "new2"])
        XCTAssertNil(byTrack["missing"])
    }

    func testAlbumsPlayFromTheWholeLibrary() throws {
        let albums = MusicRecents.albums(from: [added("a", at: 1)])

        XCTAssertEqual(albums[0].playlist.id, MusicScripts.libraryPlaylistID)
        let script = try MusicScripts.play(playlistID: albums[0].playlist.id, trackID: "06B95A881AFC9A86")
        XCTAssertTrue(script.contains("library playlist 1"))
        XCTAssertFalse(try MusicScripts.play(playlistID: "06B95A881AFC9A86", trackID: "01").contains("library playlist 1"))
        XCTAssertTrue(try MusicScripts.artwork(playlistID: MusicScripts.libraryPlaylistID, trackID: "01").contains("library playlist 1"))
    }
}

final class ArtistPageTests: XCTestCase {
    private func album(_ title: String, artist: String, tracks: [LibraryTrack], isCompilation: Bool = false) -> AlbumGroup {
        AlbumGroup(id: title, title: title, artist: artist, tracks: tracks, addedAt: 0, isCompilation: isCompilation)
    }

    func testCreditsSplitOnCommonSeparators() {
        XCTAssertEqual(ArtistCredit.names(in: "milet"), ["milet"])
        XCTAssertEqual(ArtistCredit.names(in: "Aimer & milet"), ["Aimer & milet", "Aimer", "milet"])
        XCTAssertEqual(ArtistCredit.names(in: "Aimer feat. milet"), ["Aimer feat. milet", "Aimer", "milet"])
        XCTAssertEqual(ArtistCredit.names(in: "A、B／C"), ["A、B／C", "A", "B", "C"])
        XCTAssertEqual(ArtistCredit.names(in: "A x B"), ["A x B", "A", "B"])
    }

    func testCreditsKeepNamesContainingSeparatorWords() {
        XCTAssertEqual(ArtistCredit.names(in: "Without Me"), ["Without Me"])
        XCTAssertEqual(ArtistCredit.names(in: "Fifth Harmony"), ["Fifth Harmony"])
    }

    func testCompilationTrackCountsAsTheArtistsFile() {
        let own = makeTrack(title: "own", artist: "milet", album: "Mine", path: "/a/own.flac")
        let guest = makeTrack(title: "guest", artist: "milet", album: "Mix", path: "/b/guest.flac")
        let other = makeTrack(title: "other", artist: "Someone", album: "Mix", path: "/b/other.flac")

        let artists = LibraryBrowser.artists(from: [album("Mine", artist: "milet", tracks: [own]),
                                                    album("Mix", artist: "群星", tracks: [guest, other], isCompilation: true)])

        XCTAssertEqual(artists.map(\.name), ["milet"])
        XCTAssertEqual(artists[0].guestTracks, [guest])
        XCTAssertEqual(artists[0].allTracks, [own, guest])
        XCTAssertEqual(artists[0].trackCount, 1)
    }

    func testGuestSpotOnAnotherArtistsAlbum() {
        let own = makeTrack(title: "own", artist: "B", album: "Bs", path: "/b/own.flac")
        let duet = makeTrack(title: "duet", artist: "A feat. B", album: "As", path: "/a/duet.flac")

        let artists = LibraryBrowser.artists(from: [album("As", artist: "A", tracks: [duet]),
                                                    album("Bs", artist: "B", tracks: [own])])

        XCTAssertEqual(artists.first { $0.name == "B" }?.guestTracks, [duet])
        XCTAssertEqual(artists.first { $0.name == "A" }?.guestTracks, [])
    }

    func testOwnAlbumTracksAreNotCountedTwice() {
        let track = makeTrack(title: "song", artist: "A & B", album: "Duo", path: "/d/song.flac")

        let artists = LibraryBrowser.artists(from: [album("Duo", artist: "A & B", tracks: [track])])

        XCTAssertEqual(artists[0].allTracks, [track])
    }

    func testIndexFindsTheAlbumOfALocalFile() {
        let track = makeTrack(title: "song", artist: "A", album: "Album", path: "/music/A/Album/song.flac")

        let index = LibraryIndex.build(tracks: [track], addedAt: [:], apple: [:])

        XCTAssertEqual(index.albumsByPath[track.path]?.title, "Album")
        XCTAssertEqual(index.artistsByName["A"]?.allTracks, [track])
    }

    func testSameDestinationIsNotStackedTwice() {
        let navigation = NavigationModel()
        let artist = ArtistGroup(id: "A", name: "A", albums: [])

        navigation.open(.artist(artist))
        navigation.open(.artist(artist))

        XCTAssertEqual(navigation.path.count, 1)
    }
}

final class StreamVolumeHoldTests: XCTestCase {
    private var raised = [String]()
    private var restored = [(String, [DeviceVolume])]()
    private let original = [DeviceVolume(element: 0, value: 0.6)]

    private func makeHold() -> StreamVolumeHold {
        StreamVolumeHold(raise: { [unowned self] uid in
            self.raised.append(uid)
            return self.original
        }, restore: { [unowned self] volumes, uid in
            self.restored.append((uid, volumes))
        })
    }

    func testRaisesOnceWhileHeld() {
        let hold = makeHold()

        hold.update(deviceUID: "DAC")
        hold.update(deviceUID: "DAC")

        XCTAssertEqual(raised, ["DAC"])
        XCTAssertTrue(restored.isEmpty)
    }

    func testRestoresTheOriginalValueWhenNoLongerNeeded() {
        let hold = makeHold()
        hold.update(deviceUID: "DAC")

        hold.update(deviceUID: nil)

        XCTAssertEqual(restored.map(\.0), ["DAC"])
        XCTAssertEqual(restored.first?.1, original)
    }

    func testSwitchingDevicesRestoresTheOldOne() {
        let hold = makeHold()
        hold.update(deviceUID: "DAC")

        hold.update(deviceUID: "Other")

        XCTAssertEqual(raised, ["DAC", "Other"])
        XCTAssertEqual(restored.map(\.0), ["DAC"])
    }

    func testReleaseWithoutHoldDoesNothing() {
        let hold = makeHold()

        hold.release()

        XCTAssertTrue(restored.isEmpty)
    }

    func testReleaseBeforeExclusiveLetsTheHelperSeeTheOriginalVolume() {
        let hold = makeHold()
        hold.update(deviceUID: "DAC")

        hold.release()
        hold.release()

        XCTAssertEqual(restored.count, 1)
    }
}
