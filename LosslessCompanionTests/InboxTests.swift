//
//  InboxTests.swift
//  LosslessCompanionTests
//
//  全部在暫存資料夾裡進行，不會碰到真正的音樂資料夾或垃圾桶。
//

import XCTest
@testable import LosslessCompanion

final class InboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("InboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    /// 雜訊比較能看出轉檔有沒有改到樣本
    private func makeWAV(_ url: URL, seconds: Double = 1.5, rate: Int = 44100) throws {
        let frames = Int(Double(rate) * seconds)
        var generator = SystemRandomNumberGenerator()
        var pcm = Data(capacity: frames * 4)
        for _ in 0..<(frames * 2) {
            let value = Int16.random(in: -20000...20000, using: &generator)
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVE".utf8)
        data += Data("fmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(rate) + le32(rate * 4) + le16(4) + le16(16)
        data += Data("data".utf8) + le32(pcm.count) + pcm
        try data.write(to: url)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeALAC(_ url: URL) throws {
        let wav = directory.appendingPathComponent("source-\(UUID().uuidString).wav")
        try makeWAV(wav)
        try run(["-f", "m4af", "-d", "alac/1", wav.path, url.path])
        try FileManager.default.removeItem(at: wav)
    }

    private func makeTaggedFLAC(_ url: URL, comments: [(String, String)]) throws {
        let wav = directory.appendingPathComponent("source-\(UUID().uuidString).wav")
        try makeWAV(wav)
        try run(["-f", "flac", "-d", "flac/1", wav.path, url.path])
        try FileManager.default.removeItem(at: wav)
        try FLACMetadataWriter.rewrite(url, comments: comments, picture: nil)
    }

    private func layout(_ categories: [String: [String]]) throws -> InboxLayout {
        for (category, artists) in categories {
            for artist in artists {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(category).appendingPathComponent(artist),
                                                        withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(category), withIntermediateDirectories: true)
        }
        return InboxLayout.scan(root: directory, inboxName: InboxModel.folderName, tracks: [])
    }

    private func entry(title: String, artist: String, album: String, duration: Double, genre: String? = nil,
                       track: Int = 1, year: Int = 2021) -> MusicPlaylistEntry {
        MusicPlaylistEntry(position: 0, trackID: "T\(title)", title: title, artist: artist, albumArtist: "", album: album,
                           duration: duration, trackNumber: track, discNumber: 1, year: year, cloudStatus: "", genre: genre)
    }

    // MARK: Conversion

    func testALACConvertsToAnIdentical16BitFLAC() throws {
        let source = directory.appendingPathComponent("song.m4a")
        let output = directory.appendingPathComponent("song.flac")
        try makeALAC(source)
        XCTAssertEqual(InboxConverter.codec(of: source), .alac)

        try InboxConverter.convertALAC(source, to: output)

        XCTAssertEqual(InboxConverter.codec(of: output), .flac)
        let reader = try PCMFileReader(url: output)
        XCTAssertEqual(reader.format.bitsPerSample, 16, "16-bit 的歌不能變成 24-bit")
        XCTAssertNotNil(reader.embeddedMD5)
        XCTAssertNoThrow(try InboxConverter.verifyIdentical(source, output))
    }

    func testVerificationCatchesADifferentFile() throws {
        let first = directory.appendingPathComponent("a.m4a")
        let second = directory.appendingPathComponent("b.m4a")
        try makeALAC(first)
        try makeALAC(second)
        XCTAssertThrowsError(try InboxConverter.verifyIdentical(first, second)) { error in
            XCTAssertEqual(error as? InboxConvertError, .mismatch)
        }
    }

    func testMetadataRewriteKeepsTheAudioAndAddsTagsAndCover() throws {
        let url = directory.appendingPathComponent("tagged.flac")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 300)
        try makeTaggedFLAC(url, comments: [("TITLE", "蝸旋 (feat. Ado)"), ("ARTIST", "Jon-Yakitory"), ("LYRICS", "[00:01.49]なんで")])
        let reference = directory.appendingPathComponent("reference.flac")
        try FileManager.default.copyItem(at: url, to: reference)

        try FLACMetadataWriter.rewrite(url, comments: [("TITLE", "蝸旋 (feat. Ado)")], picture: jpeg)

        XCTAssertNoThrow(try InboxConverter.verifyIdentical(reference, url))
        let blocks = FLACBlocks.read(url: url, includePicture: true)
        XCTAssertEqual(blocks.comments["TITLE"], "蝸旋 (feat. Ado)")
        XCTAssertEqual(blocks.picture, jpeg)
        XCTAssertEqual(TrackMetadata.tags(for: reference).artist, "Jon-Yakitory")
    }

    // MARK: Planning

    func testCategoryFoldersMapToGroups() {
        XCTAssertEqual(InboxPlanner.group(ofCategory: "JPOP"), .japanese)
        XCTAssertEqual(InboxPlanner.group(ofCategory: "CN & Indie Rock"), .chinese)
        XCTAssertEqual(InboxPlanner.group(ofCategory: "Classical & OST"), .classical)
        XCTAssertEqual(InboxPlanner.group(ofCategory: "西洋樂壇"), .western)
        XCTAssertNil(InboxPlanner.group(ofCategory: "Music"))
    }

    func testGenresAndScriptsPickAGroup() {
        func group(_ genre: String, _ title: String, _ artist: String) -> (InboxGroup, Bool)? {
            var metadata = InboxMetadata()
            metadata.genre = genre
            metadata.title = title
            metadata.artist = artist
            return InboxPlanner.group(for: metadata).map { ($0.group, $0.isConfident) }
        }
        XCTAssertEqual(group("動畫", "蝸旋 (feat. Ado)", "Jon-Yakitory")?.0, .japanese)
        XCTAssertEqual(group("Mandopop", "Song", "Someone")?.0, .chinese)
        XCTAssertEqual(group("原聲帶", "Main Theme", "Hans Zimmer")?.0, .classical)
        XCTAssertEqual(group("Rock", "滿月", "Deca Joins")?.0, .chinese)
        XCTAssertEqual(group("Pop", "うっせぇわ", "Ado")?.0, .japanese)
        XCTAssertEqual(group("Alternative", "Do I Wanna Know?", "Arctic Monkeys")?.0, .western)
        XCTAssertEqual(group("", "Untitled", "Someone")?.1, false, "沒有類型又只有英文時不確定")
    }

    func testNewArtistGoesToTheGenreCategoryWithTheUsualNames() throws {
        let layout = try layout(["JPOP": ["Ado"], "西洋樂壇": [], "CN & Indie Rock": [], "Classical & OST": []])
        var metadata = InboxMetadata()
        metadata.title = "蝸旋 (feat. Ado)"
        metadata.artist = "Jon-Yakitory"
        metadata.album = "蝸旋 (feat. Ado) - Single"
        metadata.genre = "動畫"
        metadata.trackNumber = 1
        metadata.year = 2021

        let plan = InboxPlanner.plan(metadata: metadata, source: .appleCatalog, fileExtension: "flac", layout: layout)

        XCTAssertTrue(plan.isConfident, plan.concerns.joined())
        XCTAssertEqual(plan.relativeDestination, "JPOP/Jon-Yakitory/Jon-Yakitory - 蝸旋 (feat. Ado) (2021)/01 - 蝸旋 (feat. Ado).flac")
    }

    func testExistingArtistAndAlbumFoldersAreReused() throws {
        let layout = try layout(["CN & Indie Rock": ["deca joins"], "西洋樂壇": []])
        let album = directory.appendingPathComponent("CN & Indie Rock/deca joins/Deca Joins - 在這裡停一下 (2026)")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        var metadata = InboxMetadata()
        metadata.title = "滿月"
        metadata.artist = "Deca Joins"
        metadata.album = "在這裡停一下"
        metadata.genre = "Alternative"
        metadata.trackNumber = 11

        let plan = InboxPlanner.plan(metadata: metadata, source: .musicLibrary, fileExtension: "FLAC", layout: layout)

        XCTAssertTrue(plan.isConfident)
        XCTAssertEqual(plan.relativeDestination, "CN & Indie Rock/deca joins/Deca Joins - 在這裡停一下 (2026)/11 - 滿月.flac")
    }

    func testDoubtfulPlansWaitForTheUser() throws {
        let layout = try layout(["JPOP": [], "西洋樂壇": []])
        var metadata = InboxMetadata()
        metadata.title = "Track"
        metadata.artist = "Somebody"
        let fromFile = InboxPlanner.plan(metadata: metadata, source: .fileTags, fileExtension: "flac", layout: layout)
        XCTAssertFalse(fromFile.isConfident, "Apple Music 找不到的歌要確認")

        metadata.genre = "Pop"
        let planned = InboxPlanner.plan(metadata: metadata, source: .musicLibrary, fileExtension: "flac", layout: layout)
        XCTAssertTrue(planned.isConfident)
        let taken = InboxPlanner.plan(metadata: metadata, source: .musicLibrary, fileExtension: "flac", layout: layout,
                                      exists: { _ in true })
        XCTAssertFalse(taken.isConfident, "目的地已有檔案時不能自動歸檔")
    }

    func testFileNamesFollowTheLibraryConvention() {
        var metadata = InboxMetadata()
        metadata.title = "a/b: c"
        metadata.trackNumber = 3
        XCTAssertEqual(InboxPlanner.fileName(for: metadata, extension: "flac"), "03 - a／b： c.flac")
        metadata.discNumber = 2
        XCTAssertEqual(InboxPlanner.fileName(for: metadata, extension: "flac"), "2-03 - a／b： c.flac")
    }

    // MARK: Lookup

    func testCatalogResultsBecomeEntries() throws {
        let json = #"{"resultCount":1,"results":[{"wrapperType":"track","trackName":"蝸旋 (feat. Ado)","artistName":"Jon-Yakitory","collectionName":"蝸旋 (feat. Ado) - Single","trackNumber":1,"discNumber":1,"primaryGenreName":"動畫","releaseDate":"2021-09-17T12:00:00Z","trackTimeMillis":231247,"trackId":1583882756,"artworkUrl100":"https://example.com/a/100x100bb.jpg"}]}"#
        let results = InboxLookup.parse(Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.entry.genre, "動畫")
        XCTAssertEqual(result.entry.year, 2021)
        XCTAssertEqual(result.entry.duration, 231.247, accuracy: 0.001)
        XCTAssertEqual(result.artworkURL, "https://example.com/a/1200x1200bb.jpg")

        var fallback = InboxMetadata()
        fallback.albumArtist = "Jon-Yakitory"
        fallback.composer = "Jon-Yakitory"
        let metadata = InboxMetadata(entry: result.entry, fallback: fallback)
        XCTAssertEqual(metadata.albumArtist, "Jon-Yakitory")
        XCTAssertEqual(metadata.composer, "Jon-Yakitory")
        XCTAssertEqual(metadata.album, "蝸旋 (feat. Ado) - Single")
    }

    func testLibraryMatchNeedsTitleArtistAndLength() throws {
        let url = directory.appendingPathComponent("x.flac")
        try makeTaggedFLAC(url, comments: [("TITLE", "滿月"), ("ARTIST", "Deca Joins")])
        let track = InboxModel.matchingTrack(for: url)
        let matches = InboxLookup.matchLibrary([track], entries: [
            entry(title: "滿月", artist: "Deca Joins", album: "在這裡停一下", duration: 200),
            entry(title: "滿月", artist: "Deca Joins", album: "在這裡停一下", duration: track.duration),
            entry(title: "滿月", artist: "別人", album: "別的", duration: track.duration),
        ])
        XCTAssertEqual(matches[url.path]?.album, "在這裡停一下")
        XCTAssertEqual(matches[url.path]?.duration ?? 0, track.duration, accuracy: 0.01)
    }

    // MARK: End to end

    private func makeInbox(entries: [MusicPlaylistEntry]) throws -> (InboxModel, LibraryOrganizer) {
        let support = directory.appendingPathComponent("support", isDirectory: true)
        let organizer = LibraryOrganizer(directory: support)
        let root = directory.appendingPathComponent("library", isDirectory: true)
        for category in ["JPOP", "西洋樂壇", "CN & Indie Rock"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(category), withIntermediateDirectories: true)
        }
        let inbox = InboxModel(stateURL: support.appendingPathComponent("inbox.json"), rootPath: { root.path }, isEnabled: { false })
        inbox.discardOriginal = { try FileManager.default.removeItem(at: $0) }
        inbox.musicLibrary = { entries }
        inbox.organize = { request, completion in
            DispatchQueue.global().async {
                let result = Result { try organizer.run(request) }
                DispatchQueue.main.async {
                    if case .success(let outcome) = result { organizer.finish(outcome.record) }
                    completion(result)
                }
            }
        }
        XCTAssertTrue(inbox.ensureFolder())
        return (inbox, organizer)
    }

    private func waitUntilIdle(_ inbox: InboxModel) {
        let done = expectation(description: "inbox idle")
        func check() {
            if !inbox.isWorking { done.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
        wait(for: [done], timeout: 30)
    }

    func testMatchedSongIsTaggedAndFiled() throws {
        let probe = directory.appendingPathComponent("probe.flac")
        try makeTaggedFLAC(probe, comments: [])
        let duration = InboxConverter.duration(of: probe)
        let (inbox, organizer) = try makeInbox(entries: [
            entry(title: "うっせぇわ", artist: "Ado", album: "狂言", duration: duration, genre: "J-Pop", track: 2, year: 2022),
        ])
        let file = inbox.folder!.appendingPathComponent("新歌/whatever.flac")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeTaggedFLAC(file, comments: [("TITLE", "うっせぇわ"), ("ARTIST", "Ado")])

        inbox.processNow()
        waitUntilIdle(inbox)

        let destination = inbox.root!.appendingPathComponent("JPOP/Ado/Ado - 狂言 (2022)/02 - うっせぇわ.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), inbox.items.map { "\($0.status) \($0.plan?.concerns ?? [])" }.joined())
        XCTAssertEqual(TrackMetadata.tags(for: destination).album, "狂言")
        XCTAssertEqual(TrackMetadata.tags(for: destination).genre, "J-Pop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), "空的資料夾要清掉")
        XCTAssertEqual(organizer.history.first?.fromInbox, true)
        XCTAssertEqual(inbox.log.count, 1)
    }

    func testUnknownALACIsConvertedAndWaitsForReview() throws {
        let (inbox, _) = try makeInbox(entries: [])
        let source = inbox.folder!.appendingPathComponent("no tags.m4a")
        try makeALAC(source)

        inbox.processNow()
        waitUntilIdle(inbox)

        let converted = inbox.folder!.appendingPathComponent("no tags.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "比對一致後原檔才移走")
        let item = try XCTUnwrap(inbox.items.first)
        XCTAssertEqual(URL(fileURLWithPath: item.path).resolvingSymlinksInPath(), converted.resolvingSymlinksInPath())
        XCTAssertEqual(item.status, .review)
        XCTAssertFalse(item.plan?.isConfident ?? true)
        XCTAssertNotNil(item.note)
    }

    /// 用真的歌和 Apple Music 目錄跑一次：TEST_RUNNER_LC_INBOX_SAMPLE=<ALAC m4a 的路徑>。檔案先複製，原檔不動
    func testRealSampleEndToEnd() throws {
        guard let sample = ProcessInfo.processInfo.environment["LC_INBOX_SAMPLE"] else { throw XCTSkip("沒有指定範例檔") }
        let (inbox, _) = try makeInbox(entries: [])
        let copy = inbox.folder!.appendingPathComponent(URL(fileURLWithPath: sample).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sample), to: copy)

        inbox.processNow()
        waitUntilIdle(inbox)

        let filed = try XCTUnwrap(inbox.log.first, inbox.items.map { "\($0.status) \($0.plan?.concerns ?? [])" }.joined())
        print("LC_INBOX_RESULT destination=\(filed.destination) note=\(filed.note ?? "")")
        let destination = inbox.root!.appendingPathComponent(filed.destination)
        let blocks = FLACBlocks.read(url: destination, includePicture: true)
        print("LC_INBOX_RESULT tags=\(blocks.comments.filter { $0.key != "LYRICS" }.sorted { $0.key < $1.key })")
        print("LC_INBOX_RESULT lyrics=\(blocks.comments["LYRICS"]?.prefix(40) ?? "none") picture=\(blocks.picture?.count ?? 0)")
        let reader = try PCMFileReader(url: destination)
        print("LC_INBOX_RESULT format=\(reader.format.sampleRate)/\(reader.format.bitsPerSample) frames=\(reader.format.frameCount)")
        XCTAssertNoThrow(try InboxConverter.verifyIdentical(URL(fileURLWithPath: sample), destination))
    }
}
