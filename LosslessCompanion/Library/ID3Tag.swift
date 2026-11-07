//
//  ID3Tag.swift
//  LosslessCompanion
//
//  WAV 與 AIFF 的 ID3 標籤。系統的音訊檔案介面讀得到歌名與歌手，
//  但沒有封面、碟號與專輯歌手，這些要自己解析。
//

import Foundation

/// WAV 與 AIFF 把標籤放在獨立的區塊，要逐一跳過才找得到，不必讀音訊資料
enum AudioChunks {
    private static let formHeaderLength: UInt64 = 12
    private static let chunkHeaderLength: UInt64 = 8

    static func id3Tag(in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: Int(formHeaderLength)), header.count == Int(formHeaderLength),
              let end = try? handle.seekToEnd() else { return nil }

        let form = String(decoding: header.prefix(4), as: UTF8.self)
        guard form == "RIFF" || form == "FORM" else { return nil }
        let isBigEndian = form == "FORM"

        var offset = formHeaderLength
        while offset + chunkHeaderLength <= end {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(chunkHeaderLength)), chunk.count == Int(chunkHeaderLength) else { return nil }
            let bytes = [UInt8](chunk)
            let sizeBytes = isBigEndian ? bytes[4..<8] : ArraySlice(bytes[4..<8].reversed())
            let size = sizeBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            // 兩種寫法都有：id3 與 ID3
            if String(decoding: bytes[0..<4], as: UTF8.self).lowercased() == "id3 " {
                return try? handle.read(upToCount: Int(size))
            }
            offset += chunkHeaderLength + size + size % 2
        }
        return nil
    }
}

/// 解析 ID3v2.2 到 v2.4。v2.2 的欄位名稱只有三個字元，所以每個欄位都有兩種名稱
enum ID3Tag {
    struct Text: Equatable {
        var title = ""
        var artist = ""
        var albumArtist = ""
        var album = ""
        /// 原始字串，常見寫法是 "2/6"
        var trackNumber = ""
        var discNumber = ""
        var genre = ""
        var composer = ""
        var year = ""
    }

    private static let tagHeaderLength = 10
    private static let frontCover: UInt8 = 3

    private static let pictureFrames: Set<String> = ["APIC", "PIC"]
    private static let textFrames: [String: WritableKeyPath<Text, String>] = [
        "TIT2": \.title, "TT2": \.title,
        "TPE1": \.artist, "TP1": \.artist,
        "TPE2": \.albumArtist, "TP2": \.albumArtist,
        "TALB": \.album, "TAL": \.album,
        "TRCK": \.trackNumber, "TRK": \.trackNumber,
        "TPOS": \.discNumber, "TPA": \.discNumber,
        "TCON": \.genre, "TCO": \.genre,
        "TCOM": \.composer, "TCM": \.composer,
        "TDRC": \.year, "TYER": \.year, "TYE": \.year
    ]

    private struct Frame {
        let id: String
        let bytes: [UInt8]
    }

    /// 解開的標籤；editable 為 false 代表有欄位長度不合理，這份標籤不能改寫，否則後面的欄位會遺失
    private struct ParsedTag {
        let version: UInt8
        let flags: UInt8
        let body: [UInt8]
        let frames: [(id: String, range: Range<Int>, payloadStart: Int, flags: UInt8)]
        let isComplete: Bool
    }

    /// 有封面類型的優先，否則用第一張
    static func picture(in tag: Data) -> Data? {
        var fallback: Data?
        for frame in frames(in: tag, matching: pictureFrames) {
            guard let picture = parsePicture(frame) else { continue }
            if picture.type == frontCover { return picture.data }
            if fallback == nil { fallback = picture.data }
        }
        return fallback
    }

    static func text(in tag: Data) -> Text {
        var text = Text()
        for frame in frames(in: tag, matching: Set(textFrames.keys)) {
            if let field = textFrames[frame.id] { text[keyPath: field] = decodeText(frame.bytes) }
        }
        return text
    }

    private static func frames(in tag: Data, matching wanted: Set<String>) -> [Frame] {
        guard let parsed = parse(tag) else { return [] }
        return parsed.frames.compactMap { frame in
            guard wanted.contains(frame.id),
                  let bytes = payload(of: parsed.body, from: frame.payloadStart, to: frame.range.upperBound,
                                      flags: frame.flags, version: parsed.version) else { return nil }
            return Frame(id: frame.id, bytes: bytes)
        }
    }

    private static func parse(_ tag: Data) -> ParsedTag? {
        let bytes = [UInt8](tag)
        guard bytes.count > tagHeaderLength, bytes.starts(with: Array("ID3".utf8)), (2...4).contains(bytes[3]) else { return nil }
        let version = bytes[3]
        let flags = bytes[5]
        var body = Array(bytes[tagHeaderLength..<min(bytes.count, tagHeaderLength + syncsafe(bytes, at: 6))])
        if flags & 0x80 != 0, version < 4 { body = removingUnsynchronisation(body) }

        var offset = 0
        if flags & 0x40 != 0, version >= 3, body.count >= 4 {
            offset = version == 4 ? syncsafe(body, at: 0) : bigEndian(body, at: 0) + 4
        }

        var frames = [(id: String, range: Range<Int>, payloadStart: Int, flags: UInt8)]()
        var isComplete = true
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        while offset >= 0, offset + headerLength <= body.count, body[offset] != 0 {
            let start = offset
            let size: Int
            switch version {
            case 2: size = Int(body[start + 3]) << 16 | Int(body[start + 4]) << 8 | Int(body[start + 5])
            case 3: size = bigEndian(body, at: start + 4)
            default: size = syncsafe(body, at: start + 4)
            }
            let end = start + headerLength + size
            guard size >= 0, end <= body.count else {
                isComplete = false
                break
            }
            offset = end
            frames.append((String(decoding: body[start..<(start + idLength)], as: UTF8.self), start..<end,
                           start + headerLength, version == 2 ? 0 : body[start + 9]))
        }
        return ParsedTag(version: version, flags: flags, body: body, frames: frames, isComplete: isComplete)
    }

    // MARK: - Writing

    private struct WrittenField {
        let id: String
        let value: String
    }

    /// 換掉要更新的文字欄位，封面與其他欄位的原始位元組不動。沿用原本的版本，
    /// v2.2 的欄位名稱和封面格式都不同，升版要全部轉換，反而容易出錯。
    /// 舊標籤無法完整解析時回傳 nil，不能冒險改寫
    static func updating(_ tag: Data?, with update: TagUpdate) -> Data? {
        guard let tag else { return build(version: 3, flags: 0, frames: fields(for: update, version: 3, old: Text()).flatMap { textFrame($0, version: 3) }) }
        guard let parsed = parse(tag), parsed.isComplete else { return nil }

        let version = parsed.version
        let fields = fields(for: update, version: version, old: text(in: tag))
        let replaced = Set(fields.map(\.id)).union(staleYearFrames(for: update, version: version))
        var pending = fields
        var output = [UInt8]()
        for frame in parsed.frames {
            if replaced.contains(frame.id) {
                if let index = pending.firstIndex(where: { $0.id == frame.id }) {
                    output += textFrame(pending.remove(at: index), version: version)
                }
            }
            else {
                output += parsed.body[frame.range]
            }
        }
        pending.forEach { output += textFrame($0, version: version) }
        // v2.4 有些軟體只在標籤開頭標示 unsynchronisation，保留這個旗標，舊欄位才解讀得回來。
        // 新欄位用 UTF-8，不含 0xFF，有沒有這個旗標都一樣
        return build(version: version, flags: version == 4 ? parsed.flags & 0x80 : 0, frames: output)
    }

    private static func build(version: UInt8, flags: UInt8, frames: [UInt8]) -> Data {
        let size = frames.count
        let header: [UInt8] = Array("ID3".utf8) + [version, 0, flags,
                                                   UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F),
                                                   UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        return Data(header + frames)
    }

    private static func fields(for update: TagUpdate, version: UInt8, old: Text) -> [WrittenField] {
        let legacy = version == 2
        var fields = [WrittenField]()
        func add(_ modern: String, _ short: String, _ value: String?) {
            if let value { fields.append(WrittenField(id: legacy ? short : modern, value: value)) }
        }
        add("TIT2", "TT2", update.title)
        add("TPE1", "TP1", update.artist)
        add("TPE2", "TP2", update.albumArtist)
        add("TALB", "TAL", update.album)
        add("TRCK", "TRK", update.trackNumber.map { TagUpdate.numbered($0, keeping: old.trackNumber) })
        add("TPOS", "TPA", update.discNumber.map { TagUpdate.numbered($0, keeping: old.discNumber) })
        add("TCON", "TCO", update.genre)
        add("TCOM", "TCM", update.composer)
        add(version == 4 ? "TDRC" : "TYER", "TYE", update.year.map(String.init))
        return fields
    }

    /// 同一份標籤裡可能同時有 TYER 與 TDRC，留著舊的另一個，讀的時候會讀到舊年份
    private static func staleYearFrames(for update: TagUpdate, version: UInt8) -> Set<String> {
        guard update.year != nil, version != 2 else { return [] }
        return ["TYER", "TDRC"]
    }

    private static func textFrame(_ field: WrittenField, version: UInt8) -> [UInt8] {
        let payload: [UInt8]
        if version == 4 {
            payload = [3] + Array(field.value.utf8)
        }
        else if field.value.allSatisfy(\.isASCII) {
            payload = [0] + Array(field.value.utf8)
        }
        else {
            payload = [1, 0xFF, 0xFE] + field.value.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
        let size = payload.count
        let id = Array(field.id.utf8)
        switch version {
        case 2: return id + [UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + payload
        case 3: return id + [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF), 0, 0] + payload
        default: return id + [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F), 0, 0] + payload
        }
    }

    /// 壓縮或加密的欄位沒有實用的寫入工具，直接略過
    private static func payload(of body: [UInt8], from start: Int, to end: Int, flags: UInt8, version: UInt8) -> [UInt8]? {
        var start = start
        switch version {
        case 3:
            guard flags & 0xC0 == 0 else { return nil }
            if flags & 0x20 != 0 { start += 1 }
        case 4:
            guard flags & 0x0C == 0 else { return nil }
            if flags & 0x40 != 0 { start += 1 }
            if flags & 0x01 != 0 { start += 4 }
        default:
            break
        }
        guard start < end else { return nil }
        let bytes = Array(body[start..<end])
        return version == 4 && flags & 0x02 != 0 ? removingUnsynchronisation(bytes) : bytes
    }

    private static func parsePicture(_ frame: Frame) -> (type: UInt8, data: Data)? {
        let bytes = frame.bytes
        guard let encoding = bytes.first else { return nil }

        // APIC 是 MIME 字串；舊版 PIC 固定三個字元的格式
        var offset = 1
        if frame.id == "PIC" {
            offset += 3
        }
        else {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        guard offset < bytes.count else { return nil }
        let type = bytes[offset]
        offset += 1

        // 描述文字的結尾：UTF-16 是對齊的兩個 0
        if encoding == 1 || encoding == 2 {
            while offset + 1 < bytes.count, bytes[offset] != 0 || bytes[offset + 1] != 0 { offset += 2 }
            offset += 2
        }
        else {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        guard offset < bytes.count else { return nil }
        return (type, Data(bytes[offset...]))
    }

    /// v2.4 的多個值以 0 分隔，取第一個。有些標籤軟體把換行寫進歌手欄，介面只顯示一行，要併起來
    private static func decodeText(_ bytes: [UInt8]) -> String {
        guard let encoding = bytes.first else { return "" }
        let body = Data(bytes.dropFirst())
        let decoded: String?
        switch encoding {
        case 0: decoded = String(data: body, encoding: .isoLatin1)
        case 1: decoded = String(data: body, encoding: .utf16)
        case 2: decoded = String(data: body, encoding: .utf16BigEndian)
        default: decoded = String(data: body, encoding: .utf8)
        }
        let first = decoded?.components(separatedBy: "\0").first ?? ""
        return first.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func syncsafe(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) << 21 | Int(bytes[offset + 1]) << 14 | Int(bytes[offset + 2]) << 7 | Int(bytes[offset + 3])
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    /// 寫入時在 0xFF 後面插入的 0x00 要拿掉
    private static func removingUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        var previous: UInt8 = 0
        for byte in bytes {
            if previous == 0xFF, byte == 0 {
                previous = byte
                continue
            }
            result.append(byte)
            previous = byte
        }
        return result
    }
}
