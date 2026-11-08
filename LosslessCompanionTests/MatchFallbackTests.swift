//
//  MatchFallbackTests.swift
//  LosslessCompanionTests
//
//  例子都取自使用者實際手動校閱過的歌：自動比對應該自己找到，也不能因此配錯。
//

import XCTest
@testable import LosslessCompanion

final class MatchFallbackTests: XCTestCase {
    private func track(_ title: String, _ artist: String, _ album: String, _ seconds: Double, number: Int = 0,
                       folder: String? = nil) -> LibraryTrack {
        let path = "/Music/\(folder ?? album)/\(number) \(title).flac"
        return LibraryTrack(path: path, title: title, artist: artist, album: album, trackNumber: number, discNumber: 0,
                            sampleRate: 44100, bitsPerSample: 16, frameCount: Int64(seconds * 44100),
                            titleKey: "", artistKey: "", searchKey: "")
    }

    private func entry(_ title: String, _ artist: String, _ album: String, _ seconds: Double, number: Int = 0,
                       id: String? = nil) -> MusicPlaylistEntry {
        MusicPlaylistEntry(position: 0, trackID: id ?? "\(title)|\(artist)|\(album)", title: title, artist: artist, albumArtist: "",
                           album: album, duration: seconds, trackNumber: number, discNumber: 1, year: 0, cloudStatus: "")
    }

    private func resolve(_ tracks: [LibraryTrack], _ entries: [MusicPlaylistEntry]) -> [String: String] {
        MatchResolver.resolve(tracks: tracks, entries: entries, decisions: MatchDecisions()).matches.mapValues(\.track.title)
    }

    // MARK: Titles

    func testBonusEditionIsNotALiveAlbum() {
        let matches = resolve([track("Snap Out Of It", "Arctic Monkeys", "AM", 192)],
                              [entry("Snap Out of It", "Arctic Monkeys", "AM (Live EP Bonus Edition)", 192)])
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(TrackMatcher.isLiveAlbum("Live at the Royal Albert Hall"))
    }

    func testLiveTitlesIgnoreTheAlbumName() {
        let matches = resolve([track("艷紅 (Live)", "deca joins", "3 Songs", 368)],
                              [entry("艷紅 (Live)", "deca joins", "3 Songs (Live) - Single", 368)])
        XCTAssertEqual(matches.count, 1)
    }

    func testNestedBracketsAreRemovedWhole() {
        let annotated = TitleFingerprint(title: "在這座城市遺失了你 (戲劇《他們創業的那些鳥事》插曲)")
        XCTAssertEqual(annotated.core, TitleFingerprint(title: "在這座城市遺失了你").core)
        XCTAssertEqual(TitleFingerprint(title: "Song (feat. A) [Live]").versions, ["live"])
    }

    func testVerAndVersionAreTheSameVersion() {
        XCTAssertEqual(TitleFingerprint(title: "Fly High (Orchestra Ver.)").versions,
                       TitleFingerprint(title: "Fly High  (Orchestra Version)").versions)
        XCTAssertNotEqual(TitleFingerprint(title: "Fly High (Orchestra Ver.)").versions,
                          TitleFingerprint(title: "Fly High (Piano Ver.)").versions)
    }

    func testDashedFileNamesAreRepaired() {
        XCTAssertEqual(TitleFingerprint.repairedFileName("Til-We-Die--Feat--Vian-Izak-"), "Til We Die (Feat Vian Izak)")
        XCTAssertEqual(TitleFingerprint(title: "Will-I-Find-My-Home--Remix-").core, TitleFingerprint(title: "Will I Find My Home (I the Ai Remix)").core)
        XCTAssertEqual(TitleFingerprint.repairedFileName("Spider-Man"), "Spider-Man", "只有一個連字號的是真的歌名")
        XCTAssertEqual(TitleFingerprint.repairedFileName("Re: Re-"), "Re: Re-")
    }

    func testCompatibilityCharactersAreFolded() {
        XCTAssertEqual(TitleFingerprint(title: "⼭").core, TitleFingerprint(title: "山").core)
        XCTAssertFalse(TitleFingerprint(title: "⼭").core.isEmpty)
    }

    // MARK: Whole albums

    private let localAOI = [("Blue Marble", 192.0), ("BLUE", 172.0), ("In the End", 192.0), ("MUSIC", 178.0)]
    private let appleAOI = [("ブルーマーブル", 192.0), ("青", 172.0), ("畢竟", 191.0), ("音楽", 178.0)]

    func testAnAlbumWithTranslatedTitlesMatchesByTrackOrderAndLength() {
        let tracks = localAOI.enumerated().map { track($1.0, "DUSTCELL", "AOI", $1.1, number: $0 + 1) }
        let entries = appleAOI.enumerated().map { entry($1.0, "DUSTCELL", "碧い海", $1.1, number: $0 + 1) }
        let matches = resolve(tracks, entries)
        XCTAssertEqual(matches["ブルーマーブル|DUSTCELL|碧い海"], "Blue Marble")
        XCTAssertEqual(matches["畢竟|DUSTCELL|碧い海"], "In the End")
        XCTAssertEqual(matches.count, 4)
    }

    func testAlbumsOfAnotherArtistOrWithDifferentLengthsDoNotAlign() {
        let tracks = localAOI.enumerated().map { track($1.0, "DUSTCELL", "AOI", $1.1, number: $0 + 1) }
        let otherArtist = appleAOI.enumerated().map { entry($1.0, "Someone Else", "碧い海", $1.1, number: $0 + 1) }
        XCTAssertTrue(resolve(tracks, otherArtist).isEmpty)

        let shifted = appleAOI.enumerated().map { entry($1.0, "DUSTCELL", "碧い海", $1.1 + Double($0 % 2) * 6, number: $0 + 1) }
        XCTAssertTrue(resolve(tracks, shifted).isEmpty, "一半的歌長度差太多，不是同一張")

        let twoTracks = Array(tracks.prefix(2))
        XCTAssertTrue(resolve(twoTracks, Array(appleAOI.enumerated().map { entry($1.0, "DUSTCELL", "碧い海", $1.1, number: $0 + 1) }.prefix(2))).isEmpty,
                      "兩首歌太少，可能只是巧合")
    }

    // MARK: Same title and length

    func testTranslatedArtistMatchesByTitleAndLength() {
        let matches = resolve([track("My Way", "André Rieu", "Voilà! The Music of Andre Rieu", 312)],
                              [entry("My Way", "安德烈・瑞歐 & 約翰 · 史特勞斯管弦樂團", "New York Memories", 311)])
        XCTAssertEqual(matches.count, 1)
    }

    func testCoversByOtherArtistsAreNotMatched() {
        // 兩邊都是拉丁字母的名字卻對不上，代表是不同的人
        XCTAssertTrue(resolve([track("Yesterday", "Frank Sinatra", "Album", 204)],
                              [entry("Yesterday", "The Beatles", "Help!", 204)]).isEmpty)
        // Music 裡有兩位不同演出者的同名歌，長度又接近，無法判斷是哪一首
        XCTAssertTrue(resolve([track("My Way", "André Rieu", "Voilà", 312)],
                              [entry("My Way", "安德烈・瑞歐", "New York Memories", 311),
                               entry("My Way", "法蘭克・辛納屈", "My Way", 314)]).isEmpty)
        // 本地有兩個長度相同的檔案時也不猜
        XCTAssertTrue(resolve([track("My Way", "André Rieu", "Voilà", 312), track("My Way", "André Rieu", "Live", 312, folder: "Live copy")],
                              [entry("My Way", "安德烈・瑞歐", "New York Memories", 311)]).isEmpty)
        // 太短的歌名不夠獨特
        XCTAssertTrue(resolve([track("Go", "André Rieu", "Voilà", 200)], [entry("Go", "安德烈・瑞歐", "X", 200)]).isEmpty)
    }
}
