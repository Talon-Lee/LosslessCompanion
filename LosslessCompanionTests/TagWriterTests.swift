//
//  TagWriterTests.swift
//  LosslessCompanionTests
//

import AudioToolbox
import XCTest
@testable import LosslessCompanion

private func littleEndian(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
}

private func bigEndian(_ value: Int) -> [UInt8] {
    littleEndian(value).reversed()
}

private func chunk(_ id: String, _ body: [UInt8], bigEndianSize: Bool = false) -> [UInt8] {
    Array(id.utf8) + (bigEndianSize ? bigEndian(body.count) : littleEndian(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
}

private func pcm(frames: Int) -> [UInt8] {
    (0..<frames * 4).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
}

private func wav(frames: Int = 44_100, after: [UInt8] = [], before: [UInt8] = []) -> Data {
    let format: [UInt8] = [1, 0, 2, 0] + littleEndian(44_100) + littleEndian(176_400) + [4, 0, 16, 0]
    let body = Array("WAVE".utf8) + chunk("fmt ", format) + before + chunk("data", pcm(frames: frames)) + after
    return Data(Array("RIFF".utf8) + littleEndian(body.count) + body)
}

private func aiff(frames: Int = 44_100, after: [UInt8] = []) -> Data {
    // 44100 的 80 位元延伸精度浮點數
    let rate: [UInt8] = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
    let common: [UInt8] = [0, 2] + bigEndian(frames) + [0, 16] + rate
    let samples = [UInt8](repeating: 0, count: 8) + pcm(frames: frames)
    let body = Array("AIFF".utf8) + chunk("COMM", common, bigEndianSize: true) + chunk("SSND", samples, bigEndianSize: true) + after
    return Data(Array("FORM".utf8) + bigEndian(body.count) + body)
}

private func syncsafe(_ value: Int) -> [UInt8] {
    [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
}

private func id3Frame(_ id: String, _ payload: [UInt8], version: UInt8) -> [UInt8] {
    switch version {
    case 2: return Array(id.utf8) + Array(bigEndian(payload.count).suffix(3)) + payload
    case 3: return Array(id.utf8) + bigEndian(payload.count) + [0, 0] + payload
    default: return Array(id.utf8) + syncsafe(payload.count) + [0, 0] + payload
    }
}

private func id3(version: UInt8, flags: UInt8 = 0, _ frames: [UInt8]) -> [UInt8] {
    Array("ID3".utf8) + [version, 0, flags] + syncsafe(frames.count) + frames
}

private func latin1(_ text: String) -> [UInt8] {
    [0] + Array(text.utf8)
}

final class TagWriterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func flac(comments: [String] = ["TITLE=Old", "ARTIST=Old Artist", "ISRC=TW1234567890", "TRACKNUMBER=3/12"],
                      padding: Int = 4096) throws -> URL {
        let source = try write(wav(), name: "source.wav")
        let converted = folder.appendingPathComponent("converted.flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", source.path, converted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.removeItem(at: source)

        // 系統編碼器寫的中繼資料換成測試要的樣子，音訊段落不動
        let original = [UInt8](try Data(contentsOf: converted))
        var offset = 4
        var streamInfo = [UInt8]()
        var isLast = false
        while !isLast {
            let type = original[offset] & 0x7F
            isLast = original[offset] & 0x80 != 0
            let length = Int(original[offset + 1]) << 16 | Int(original[offset + 2]) << 8 | Int(original[offset + 3])
            if type == 0 { streamInfo = Array(original[(offset + 4)..<(offset + 4 + length)]) }
            offset += 4 + length
        }
        var vorbis = littleEndian(6) + Array("vendor".utf8) + littleEndian(comments.count)
        for comment in comments { vorbis += littleEndian(comment.utf8.count) + Array(comment.utf8) }

        var result = Array("fLaC".utf8)
        func block(_ type: UInt8, _ body: [UInt8], last: Bool = false) {
            result += [type | (last ? 0x80 : 0), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
        }
        block(0, streamInfo)
        block(4, vorbis)
        let image: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]
        let mime = Array("image/jpeg".utf8)
        block(6, bigEndian(3) + bigEndian(mime.count) + mime + bigEndian(0) + [UInt8](repeating: 0, count: 16) + bigEndian(image.count) + image,
              last: padding == 0)
        if padding > 0 { block(1, [UInt8](repeating: 0, count: padding), last: true) }
        result += original[offset...]
        try FileManager.default.removeItem(at: converted)
        return try write(Data(result), name: "song.flac")
    }

    private func audio(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var offset = 4
        var isLast = false
        while !isLast {
            isLast = data[offset] & 0x80 != 0
            offset += 4 + (Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3]))
        }
        return data[offset...]
    }

    func testFLACKeepsAudioAndOtherFields() throws {
        let url = try flac()
        let audio = try audio(of: url)
        let picture = FLACBlocks.read(url: url, includePicture: true).picture

        try TagWriter.apply(TagUpdate(title: "新歌名", artist: "新歌手", trackNumber: 5, year: 2024), to: url)

        let contents = FLACBlocks.read(url: url, includePicture: true)
        XCTAssertEqual(contents.comments["TITLE"], "新歌名")
        XCTAssertEqual(contents.comments["ARTIST"], "新歌手")
        XCTAssertEqual(contents.comments["ISRC"], "TW1234567890")
        XCTAssertEqual(contents.comments["TRACKNUMBER"], "5/12")
        XCTAssertEqual(contents.comments["DATE"], "2024")
        XCTAssertEqual(contents.picture, picture)
        XCTAssertEqual(try self.audio(of: url), audio)
        XCTAssertEqual(try LibraryInspector.inspect(url: url).title, "新歌名")
    }

    func testFLACUsesPaddingSoFileSizeStaysTheSame() throws {
        let url = try flac()
        let size = try Data(contentsOf: url).count
        try TagWriter.apply(TagUpdate(title: "Longer Title Than Before"), to: url)
        XCTAssertEqual(try Data(contentsOf: url).count, size)
    }

    func testFLACWithoutPaddingShiftsAudioSafely() throws {
        let url = try flac(padding: 0)
        let audio = try audio(of: url)
        try TagWriter.apply(TagUpdate(title: "A Much Longer Title"), to: url)
        XCTAssertEqual(try self.audio(of: url), audio)
        XCTAssertEqual(FLACBlocks.read(url: url).comments["TITLE"], "A Much Longer Title")
    }

    func testFLACRemovesExtraValuesOfTheSameField() throws {
        let url = try flac(comments: ["ARTIST=One", "GENRE=Rock", "artist=Two"])
        try TagWriter.apply(TagUpdate(artist: "New"), to: url)
        XCTAssertEqual(FLACBlocks.read(url: url).comments["ARTIST"], "New")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("artist=Two"))
    }

    func testFLACRestoreBringsBackOriginalTags() throws {
        let url = try flac()
        let audio = try audio(of: url)
        let snapshot = try TagWriter.apply(TagUpdate(title: "Changed", album: "Changed"), to: url)
        try TagWriter.restore(snapshot, to: url)
        let comments = FLACBlocks.read(url: url).comments
        XCTAssertEqual(comments["TITLE"], "Old")
        XCTAssertNil(comments["ALBUM"])
        XCTAssertEqual(try self.audio(of: url), audio)
    }

    func testFLACWithoutCommentBlockGetsOneAndUndoRemovesIt() throws {
        var bytes = [UInt8](try Data(contentsOf: try flac()))
        // 把註解區塊的型別改成未知型別不合規範，改用只保留 STREAMINFO 的方式重排
        let length = Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        var offset = 8 + length
        var isLast = false
        while !isLast {
            isLast = bytes[offset] & 0x80 != 0
            offset += 4 + (Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        bytes[4] |= 0x80
        let url = try write(Data(bytes[0..<(8 + length)] + bytes[offset...]), name: "bare.flac")

        let snapshot = try TagWriter.apply(TagUpdate(title: "Added"), to: url)
        XCTAssertNil(snapshot)
        XCTAssertEqual(FLACBlocks.read(url: url).comments["TITLE"], "Added")
        try TagWriter.restore(snapshot, to: url)
        XCTAssertNil(FLACBlocks.read(url: url).comments["TITLE"])
    }

    func testModificationDateIsPreserved() throws {
        let url = try flac()
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        try TagWriter.apply(TagUpdate(title: "New"), to: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, date)
    }

    func testNoTemporaryFilesLeftBehind() throws {
        let url = try flac()
        try TagWriter.apply(TagUpdate(title: "New"), to: url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["song.flac"])
    }

    func testBrokenFileStaysUntouched() throws {
        let url = try write(Data("fLaC not really".utf8), name: "broken.flac")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try TagWriter.apply(TagUpdate(title: "New"), to: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testWAVWithoutTagsGetsChunkAndUndoRemovesIt() throws {
        let original = wav()
        let url = try write(original, name: "plain.wav")
        let snapshot = try TagWriter.apply(TagUpdate(title: "歌名", artist: "Artist", albumArtist: "群星", trackNumber: 2), to: url)
        XCTAssertNil(snapshot)

        let tags = TrackMetadata.tags(for: url)
        XCTAssertEqual(tags.title, "歌名")
        XCTAssertEqual(tags.artist, "Artist")
        XCTAssertEqual(tags.albumArtist, "群星")
        XCTAssertEqual(tags.trackNumber, 2)

        try TagWriter.restore(snapshot, to: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWAVKeepsOtherChunksByteForByte() throws {
        let tag = id3(version: 3, id3Frame("TIT2", latin1("Old"), version: 3)
                      + id3Frame("APIC", [0, 0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F, 0x6A, 0x70, 0x65, 0x67, 0, 3, 0, 0xFF, 0xD8, 0xFF], version: 3))
        let extra = chunk("bext", [UInt8](repeating: 9, count: 33)) + chunk("id3 ", tag) + chunk("iXML", Array("<x/>".utf8))
        let original = wav(after: extra, before: chunk("JUNK", [UInt8](repeating: 0, count: 28)))
        let url = try write(original, name: "chunks.wav")
        let picture = ID3Tag.picture(in: Data(tag))

        let snapshot = try TagWriter.apply(TagUpdate(title: "New", year: 2021), to: url)
        XCTAssertEqual(snapshot, Data(tag))

        let data = try Data(contentsOf: url)
        for marker in ["JUNK", "data", "bext", "iXML"] { XCTAssertNotNil(data.range(of: Data(marker.utf8))) }
        let tagged = try XCTUnwrap(AudioChunks.id3Tag(in: url))
        XCTAssertEqual(ID3Tag.text(in: tagged).title, "New")
        XCTAssertEqual(ID3Tag.text(in: tagged).year, "2021")
        XCTAssertEqual(ID3Tag.picture(in: tagged), picture)
        XCTAssertEqual(Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24, data.count - 8)

        try TagWriter.restore(snapshot, to: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLISTChunkDoesNotOverrideWrittenTitle() throws {
        let info = Array("INFO".utf8) + chunk("INAM", Array("Stale Title\0".utf8))
        let tag = id3(version: 3, id3Frame("TIT2", latin1("Old"), version: 3))
        let url = try write(wav(after: chunk("LIST", info) + chunk("id3 ", tag)), name: "list.wav")
        try TagWriter.apply(TagUpdate(title: "Fresh"), to: url)
        XCTAssertEqual(TrackMetadata.tags(for: url).title, "Fresh")
    }

    func testVersion24KeepsFlagAndWritesUTF8() throws {
        let frames = id3Frame("TIT2", [3] + Array("Old".utf8), version: 4) + id3Frame("TXXX", [3, 0x41, 0, 0x42], version: 4)
        let tag = id3(version: 4, flags: 0x80, frames)
        let url = try write(wav(after: chunk("id3 ", tag)), name: "v24.wav")
        try TagWriter.apply(TagUpdate(title: "夜に駆ける", year: 2020), to: url)

        let written = try XCTUnwrap(AudioChunks.id3Tag(in: url))
        XCTAssertEqual(written[3], 4)
        XCTAssertEqual(written[5], 0x80)
        XCTAssertEqual(ID3Tag.text(in: written).title, "夜に駆ける")
        XCTAssertNotNil(written.range(of: Data("TDRC".utf8)))
        XCTAssertNotNil(written.range(of: Data("TXXX".utf8)))
    }

    func testVersion22AIFFKeepsItsFormat() throws {
        let frames = id3Frame("TT2", latin1("Old"), version: 2) + id3Frame("PIC", [0, 0x4A, 0x50, 0x47, 3, 0, 0xFF, 0xD8], version: 2)
        let tag = id3(version: 2, frames)
        let url = try write(aiff(after: chunk("ID3 ", tag, bigEndianSize: true)), name: "old.aif")
        let picture = ID3Tag.picture(in: Data(tag))
        try TagWriter.apply(TagUpdate(title: "新しい", album: "Album"), to: url)

        let written = try XCTUnwrap(AudioChunks.id3Tag(in: url))
        XCTAssertEqual(written[3], 2)
        XCTAssertEqual(ID3Tag.text(in: written).title, "新しい")
        XCTAssertEqual(ID3Tag.text(in: written).album, "Album")
        XCTAssertEqual(ID3Tag.picture(in: written), picture)
        XCTAssertEqual(TrackMetadata.tags(for: url).title, "新しい")
    }

    func testTrackTotalIsKept() {
        XCTAssertEqual(TagUpdate.numbered(7, keeping: "3/12"), "7/12")
        XCTAssertEqual(TagUpdate.numbered(7, keeping: "3"), "7")
    }

    func testUnreadableTagIsNotRewritten() {
        // 欄位長度超出標籤，繼續寫會丟掉後面的欄位
        var tag = id3(version: 3, id3Frame("TIT2", latin1("Old"), version: 3))
        tag[17] = 0x7F
        XCTAssertNil(ID3Tag.updating(Data(tag), with: TagUpdate(title: "New")))
    }

    func testOddSizedLastChunkGetsPadBeforeNewTag() throws {
        var data = [UInt8](wav(after: Array("bext".utf8) + littleEndian(3) + [1, 2, 3]))
        data.replaceSubrange(4..<8, with: littleEndian(data.count - 8))
        let url = try write(Data(data), name: "odd.wav")
        try TagWriter.apply(TagUpdate(title: "New"), to: url)
        XCTAssertEqual(ID3Tag.text(in: try XCTUnwrap(AudioChunks.id3Tag(in: url))).title, "New")
    }

    /// 真實檔案的複本才能跑，資料夾由 LC_TAG_FIXTURES 指定；每個檔案寫入後由外部程式比對音訊
    func testFixturesFromRealLibrary() throws {
        guard let path = ProcessInfo.processInfo.environment["LC_TAG_FIXTURES"] else { throw XCTSkip("沒有指定真實檔案複本") }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { TagWriter.supports($0) }
        XCTAssertFalse(files.isEmpty)
        var snapshots = [String: String]()
        for file in files {
            let before = TrackMetadata.tags(for: file)
            let snapshot = try TagWriter.apply(TagUpdate(title: "測試 Title ✓", artist: "測試歌手", albumArtist: "專輯歌手", album: "測試專輯",
                                                         trackNumber: 42, discNumber: 3, genre: "J-Pop", composer: "作曲者", year: 1999), to: file)
            let after = TrackMetadata.tags(for: file)
            XCTAssertEqual(after.title, "測試 Title ✓", file.lastPathComponent)
            XCTAssertEqual(after.artist, "測試歌手", file.lastPathComponent)
            XCTAssertEqual(after.albumArtist, "專輯歌手", file.lastPathComponent)
            XCTAssertEqual(after.album, "測試專輯", file.lastPathComponent)
            XCTAssertEqual(after.trackNumber, 42, file.lastPathComponent)
            XCTAssertEqual(after.discNumber, 3, file.lastPathComponent)
            XCTAssertEqual(after.year, 1999, file.lastPathComponent)
            XCTAssertEqual(after.composer, "作曲者", file.lastPathComponent)
            XCTAssertEqual(after.genre, "J-Pop", file.lastPathComponent)
            XCTAssertNotEqual(before.title, after.title)
            snapshots[file.lastPathComponent] = snapshot?.base64EncodedString() ?? ""
        }
        try JSONEncoder().encode(snapshots).write(to: URL(fileURLWithPath: path).appendingPathComponent("snapshots.json"))
    }

    /// 上面那個測試之後由外部比對，再跑這個還原，檢查還原結果
    func testFixturesRestore() throws {
        guard let path = ProcessInfo.processInfo.environment["LC_TAG_RESTORE"] else { throw XCTSkip("沒有指定真實檔案複本") }
        let folder = URL(fileURLWithPath: path)
        let snapshots = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent("snapshots.json")))
        for (name, snapshot) in snapshots {
            try TagWriter.restore(snapshot.isEmpty ? nil : Data(base64Encoded: snapshot), to: folder.appendingPathComponent(name))
        }
    }
}
