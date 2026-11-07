//
//  ArtworkTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

private let picture: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x10, 0x20, 0x30]

private func syncsafe(_ value: Int) -> [UInt8] {
    [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
}

private func bigEndian(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

private func littleEndian(_ value: Int) -> [UInt8] {
    bigEndian(value).reversed()
}

private func apic(_ image: [UInt8] = picture, type: UInt8 = 3, encoding: UInt8 = 0, description: [UInt8] = [0]) -> [UInt8] {
    [encoding] + Array("image/jpeg".utf8) + [0, type] + description + image
}

private func frame(_ id: String, _ body: [UInt8], version: UInt8 = 3) -> [UInt8] {
    Array(id.utf8) + (version == 4 ? syncsafe(body.count) : bigEndian(body.count)) + [0, 0] + body
}

private func tag(version: UInt8 = 3, flags: UInt8 = 0, _ frames: [UInt8]) -> Data {
    Data(Array("ID3".utf8) + [version, 0, flags] + syncsafe(frames.count) + frames)
}

private func chunk(_ name: String, _ body: [UInt8], littleEndianSize: Bool = true) -> [UInt8] {
    let size = littleEndianSize ? littleEndian(body.count) : bigEndian(body.count)
    return Array(name.utf8) + size + body + (body.count % 2 == 1 ? [0] : [])
}

private func atom(_ name: String, _ body: [UInt8]) -> [UInt8] {
    bigEndian(body.count + 8) + Array(name.utf8) + body
}

/// 可以通過 LibraryInspector 檢查的最小 WAV
private func wavFile(_ extraChunks: [UInt8] = []) -> Data {
    let format = littleEndianUInt16(1) + littleEndianUInt16(2) + littleEndian(44_100) + littleEndian(176_400)
        + littleEndianUInt16(4) + littleEndianUInt16(16)
    let body = Array("WAVE".utf8) + chunk("fmt ", format) + chunk("data", [0, 0, 0, 0]) + extraChunks
    return Data(Array("RIFF".utf8) + littleEndian(body.count) + body)
}

private func littleEndianUInt16(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
}

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

final class ID3TagTests: XCTestCase {
    func testVersion3Picture() {
        XCTAssertEqual(ID3Tag.picture(in: tag(frame("APIC", apic()))), Data(picture))
    }

    func testVersion4UsesSyncsafeFrameSizes() {
        let large = [UInt8](repeating: 0x42, count: 300)
        XCTAssertEqual(ID3Tag.picture(in: tag(version: 4, frame("APIC", apic(large), version: 4))), Data(large))
    }

    func testVersion2LegacyFrame() {
        let body = [UInt8(0)] + Array("JPG".utf8) + [3, 0] + picture
        let legacy = Array("PIC".utf8) + [0, 0, UInt8(body.count)] + body
        XCTAssertEqual(ID3Tag.picture(in: tag(version: 2, legacy)), Data(picture))
    }

    func testWideDescriptionEndsOnAlignedZeros() {
        let description: [UInt8] = [0xFF, 0xFE, 0x41, 0x00, 0x00, 0x01, 0x00, 0x00]
        XCTAssertEqual(ID3Tag.picture(in: tag(frame("APIC", apic(encoding: 1, description: description)))), Data(picture))
    }

    func testFrontCoverWinsOverOtherPictures() {
        let back: [UInt8] = [9, 9, 9]
        let frames = frame("APIC", apic(back, type: 4)) + frame("APIC", apic())
        XCTAssertEqual(ID3Tag.picture(in: tag(frames)), Data(picture))
    }

    func testFirstPictureIsUsedWithoutAFrontCover() {
        let other: [UInt8] = [7, 7, 7]
        let frames = frame("APIC", apic(other, type: 0)) + frame("APIC", apic([8, 8], type: 5))
        XCTAssertEqual(ID3Tag.picture(in: tag(frames)), Data(other))
    }

    func testTextFramesAreSkipped() {
        let frames = frame("TIT2", [0] + Array("Song".utf8)) + frame("APIC", apic())
        XCTAssertEqual(ID3Tag.picture(in: tag(frames)), Data(picture))
    }

    func testUnsynchronisedTagIsRestored() {
        let body = frame("APIC", apic())
        var encoded = [UInt8]()
        for byte in body {
            encoded.append(byte)
            if byte == 0xFF { encoded.append(0) }
        }
        XCTAssertEqual(ID3Tag.picture(in: tag(flags: 0x80, encoded)), Data(picture))
    }

    func testTagWithoutPicture() {
        XCTAssertNil(ID3Tag.picture(in: tag(frame("TIT2", [0, 65]))))
    }

    func testTruncatedFrameIsIgnored() {
        var frames = frame("APIC", apic())
        frames.removeLast(3)
        XCTAssertNil(ID3Tag.picture(in: tag(frames)))
    }
}

private func utf16Text(_ text: String) -> [UInt8] {
    [1, 0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
}

final class ID3TextTests: XCTestCase {
    func testVersion3WideText() {
        let frames = frame("TPE2", utf16Text("サカナクション")) + frame("TPOS", [0] + Array("2/6".utf8))
        XCTAssertEqual(ID3Tag.text(in: tag(frames)), ID3Tag.Text(albumArtist: "サカナクション", discNumber: "2/6"))
    }

    func testVersion4UsesUTF8AndTerminators() {
        let frames = frame("TPE2", [3] + Array("陳珊妮".utf8) + [0], version: 4)
            + frame("TPOS", [3] + Array("1/2".utf8) + [0], version: 4)
        XCTAssertEqual(ID3Tag.text(in: tag(version: 4, frames)), ID3Tag.Text(albumArtist: "陳珊妮", discNumber: "1/2"))
    }

    func testVersion2ShortNames() {
        func legacy(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + [0, 0, UInt8(body.count)] + body }
        let frames = legacy("TP2", [0] + Array("Band".utf8)) + legacy("TPA", [0] + Array("3".utf8))
        XCTAssertEqual(ID3Tag.text(in: tag(version: 2, frames)), ID3Tag.Text(albumArtist: "Band", discNumber: "3"))
    }

    func testOnlyTheFirstOfSeveralValuesIsUsed() {
        let body = [3] + Array("First".utf8) + [0] + Array("Second".utf8)
        XCTAssertEqual(ID3Tag.text(in: tag(version: 4, frame("TPE2", body, version: 4))).albumArtist, "First")
    }

    func testLineBreaksBecomeOneLine() {
        let frames = frame("TPE2", [3] + Array("Soloists\r\nOrchestra, Conductor \n".utf8))
        XCTAssertEqual(ID3Tag.text(in: tag(frames)).albumArtist, "Soloists, Orchestra, Conductor")
    }

    func testPictureFramesDoNotDisturbText() {
        let frames = frame("APIC", apic()) + frame("TPE2", [3] + Array("Band".utf8))
        XCTAssertEqual(ID3Tag.text(in: tag(frames)).albumArtist, "Band")
    }

    func testMissingFramesStayEmpty() {
        XCTAssertEqual(ID3Tag.text(in: tag(frame("TSSE", [0, 65]))), ID3Tag.Text())
    }
}

final class WAVTagTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func taggedWAV() throws -> URL {
        let frames = frame("TPE2", [3] + Array("Album Artist".utf8)) + frame("TPOS", [0] + Array("2/6".utf8))
        let url = directory.appendingPathComponent("a.wav")
        try wavFile(chunk("id3 ", [UInt8](tag(frames)))).write(to: url)
        return url
    }

    func testDiscAndAlbumArtistComeFromTheTag() throws {
        let tags = TrackMetadata.tags(for: try taggedWAV())
        XCTAssertEqual(tags.albumArtist, "Album Artist")
        XCTAssertEqual(tags.discNumber, 2)
    }

    func testNewScanFillsMissingArtistFromAlbumArtist() throws {
        let track = try LibraryInspector.inspect(url: try taggedWAV())
        XCTAssertEqual(track.artist, "Album Artist")
        XCTAssertEqual(track.albumArtist, "Album Artist")
        XCTAssertEqual(track.discNumber, 2)
    }

    func testOldIndexEntryCatchesUpWithoutReinspecting() throws {
        let url = try taggedWAV()
        var old = makeTrack(title: "Song", artist: "", path: url.path)
        old.discNumber = 0
        old.tagVersion = 2

        let refreshed = old.updating(with: TrackMetadata.tags(for: url))

        XCTAssertEqual(refreshed.discNumber, 2)
        XCTAssertEqual(refreshed.artist, "Album Artist")
        XCTAssertEqual(refreshed.albumArtist, "Album Artist")
        XCTAssertEqual(refreshed.tagVersion, TrackMetadata.version)
        XCTAssertEqual(refreshed.frameCount, old.frameCount)
        XCTAssertTrue(refreshed.artistKey.contains(SearchText.normalize("Album Artist")))
        XCTAssertTrue(refreshed.searchKey.contains(SearchText.normalize("Album Artist")))
    }

    func testDiscsPlayInOrder() {
        var first = makeTrack(title: "Disc Two Opener", number: 1, path: "/album/2-01.wav")
        first.discNumber = 2
        var second = makeTrack(title: "Disc One Closer", number: 12, path: "/album/1-12.wav")
        second.discNumber = 1

        let album = LibraryBrowser.albums(from: [first, second], addedAt: [:]).first

        XCTAssertEqual(album?.tracks.map(\.title), ["Disc One Closer", "Disc Two Opener"])
    }
}

final class EmbeddedArtworkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testWAVChunkAfterOddSizedChunk() throws {
        let extra = chunk("LIST", [1, 2, 3]) + chunk("id3 ", [UInt8](tag(frame("APIC", apic()))))
        let url = try write(wavFile(extra), "a.wav")
        XCTAssertEqual(TrackArtwork.embedded(in: url), Data(picture))
    }

    func testUppercaseChunkName() throws {
        let url = try write(wavFile(chunk("ID3 ", [UInt8](tag(frame("APIC", apic()))))), "a.wav")
        XCTAssertEqual(TrackArtwork.embedded(in: url), Data(picture))
    }

    func testAIFFChunkIsBigEndian() throws {
        let sound = chunk("SSND", [UInt8](repeating: 0, count: 301), littleEndianSize: false)
        let id3 = chunk("ID3 ", [UInt8](tag(frame("APIC", apic()))), littleEndianSize: false)
        let body = Array("AIFF".utf8) + sound + id3
        let url = try write(Data(Array("FORM".utf8) + bigEndian(body.count) + body), "a.aif")
        XCTAssertEqual(TrackArtwork.embedded(in: url), Data(picture))
    }

    func testM4ACoverAtom() throws {
        let data = atom("data", [0, 0, 0, 13, 0, 0, 0, 0] + picture)
        let ilst = atom("ilst", atom("aART", [0, 0]) + atom("covr", data))
        let moov = atom("moov", atom("mvhd", [0, 0]) + atom("udta", atom("meta", [0, 0, 0, 0] + ilst)))
        let url = try write(Data(atom("ftyp", Array("M4A ".utf8)) + moov), "a.m4a")
        XCTAssertEqual(TrackArtwork.embedded(in: url), Data(picture))
    }

    func testWAVWithoutTagHasNoPicture() throws {
        XCTAssertNil(TrackArtwork.embedded(in: try write(wavFile(), "a.wav")))
    }

    func testEmbeddedPictureWinsOverFolderImage() throws {
        _ = try write(Data([1, 2, 3]), "cover.jpg")
        let url = try write(wavFile(chunk("id3 ", [UInt8](tag(frame("APIC", apic()))))), "a.wav")
        XCTAssertEqual(TrackArtwork.data(for: try LibraryInspector.inspect(url: url)), Data(picture))
    }

    func testFolderImageComesBeforeBorrowing() throws {
        _ = try write(Data([1, 2, 3]), "cover.jpg")
        _ = try write(wavFile(chunk("id3 ", [UInt8](tag(frame("APIC", apic()))))), "a.wav")
        let plain = try write(wavFile(), "b.wav")
        XCTAssertEqual(TrackArtwork.data(for: try LibraryInspector.inspect(url: plain)), Data([1, 2, 3]))
    }

    func testBorrowsFromAnotherFileOfTheSameAlbum() throws {
        _ = try write(wavFile(chunk("id3 ", [UInt8](tag(frame("APIC", apic()))))), "b.wav")
        let plain = try write(wavFile(), "a.wav")
        XCTAssertEqual(TrackArtwork.data(for: try LibraryInspector.inspect(url: plain)), Data(picture))
    }

    func testDoesNotBorrowFromAnotherAlbum() throws {
        _ = try write(wavFile(chunk("id3 ", [UInt8](tag(frame("APIC", apic()))))), "b.wav")
        let plain = try write(wavFile(), "a.wav")
        let track = makeTrack(title: "A", album: "Another Album", path: plain.path)
        XCTAssertNil(TrackArtwork.data(for: track))
    }
}

final class LibraryScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // 暫存目錄經過 /var 捷徑；資料夾被刪掉後就解不開，要從一開始就用真實路徑
        let temporary = try makeDirectory()
        let resolved = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String, files: [String]) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try wavFile().write(to: url.appendingPathComponent(file)) }
        return url.path
    }

    private func library(_ folders: [String]) -> LocalLibrary {
        LocalLibrary(folders: folders, cacheURL: root.appendingPathComponent("cache.json"))
    }

    func testUnreachableFolderKeepsItsTracksWhileOthersAreScanned() throws {
        let kept = try folder("kept", files: ["a.wav"])
        let removable = try folder("removable", files: ["b.wav", "c.wav"])
        let library = library([kept, removable])
        library.scan(folders: [kept, removable])
        library.publishNow()
        XCTAssertEqual(library.tracks.count, 3)

        try FileManager.default.removeItem(atPath: removable)
        try wavFile().write(to: URL(fileURLWithPath: kept).appendingPathComponent("new.wav"))
        library.scan(folders: [kept, removable])
        library.publishNow()

        XCTAssertEqual(library.tracks.count, 4)
    }

    func testRemovedFolderLeavesTheLibrary() throws {
        let first = try folder("first", files: ["a.wav"])
        let second = try folder("second", files: ["b.wav"])
        let library = library([first, second])
        library.scan(folders: [first, second])
        library.scan(folders: [first])
        library.publishNow()

        XCTAssertEqual(library.tracks.map(\.url.lastPathComponent), ["a.wav"])
    }

    func testFolderInsideAnotherFolderCountsFilesOnce() throws {
        let parent = try folder("parent", files: ["a.wav"])
        let child = try folder("parent/child", files: ["b.wav"])
        let library = library([parent, child])
        library.scan(folders: [parent, child])
        library.publishNow()

        XCTAssertEqual(library.tracks.count, 2)
    }

    func testTrackCountBelongsToItsFolder() throws {
        let first = try folder("music", files: ["a.wav", "b.wav"])
        let second = try folder("music-extra", files: ["c.wav"])
        let library = library([first, second])
        library.scan(folders: [first, second])
        library.publishNow()

        XCTAssertEqual(library.trackCount(in: first), 2)
        XCTAssertEqual(library.trackCount(in: second), 1)
    }
}
