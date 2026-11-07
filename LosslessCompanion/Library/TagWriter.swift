//
//  TagWriter.swift
//  LosslessCompanion
//
//  把歌名等資料寫進檔案。只換掉標籤那一段，其餘位元組原樣搬到新檔，音訊資料一個位元都不變。
//  先寫到同資料夾的暫存檔，逐段比對、重新檢查過才原子替換，中途失敗時原檔完全不受影響。
//

import Darwin
import Foundation

struct TagUpdate: Codable, Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var genre: String?
    var composer: String?
    var year: Int?

    var isEmpty: Bool { self == TagUpdate() }

    /// 舊值常寫成 "3/12"，只換前面的數字，總數留著
    static func numbered(_ number: Int, keeping old: String) -> String {
        guard let slash = old.firstIndex(of: "/") else { return String(number) }
        return "\(number)\(old[slash...])"
    }
}

enum TagWriteError: LocalizedError, Equatable {
    case unsupported
    case malformed
    case tooLarge
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return String(localized: "這種格式不能寫入標籤")
        case .malformed: return String(localized: "檔案結構不符合預期，沒有改動")
        case .tooLarge: return String(localized: "標籤太大，沒有改動")
        case .verificationFailed: return String(localized: "寫入後比對不符，沒有改動")
        }
    }
}

enum TagWriter {
    private enum Container {
        case flac, chunks
    }

    private static func container(of url: URL) -> Container? {
        switch url.pathExtension.lowercased() {
        case "flac": return .flac
        case "wav", "wave", "aif", "aiff", "aifc": return .chunks
        default: return nil
        }
    }

    static func supports(_ url: URL) -> Bool {
        container(of: url) != nil
    }

    /// 回傳寫入前的標籤，復原時交給 restore；原本沒有標籤時是 nil
    @discardableResult
    static func apply(_ update: TagUpdate, to url: URL) throws -> Data? {
        switch container(of: url) {
        case .flac:
            let file = try FLACFile(url: url)
            var comments = try VorbisComments(block: file.comments)
            comments.apply(update)
            try file.replaceComments(with: comments.encoded, in: url)
            return file.comments
        case .chunks:
            let file = try ChunkFile(url: url)
            guard let tag = ID3Tag.updating(file.tag, with: update) else { throw TagWriteError.malformed }
            try file.replaceTag(with: tag, in: url)
            return file.tag
        case nil:
            throw TagWriteError.unsupported
        }
    }

    /// 把 apply 回傳的內容原樣寫回
    static func restore(_ snapshot: Data?, to url: URL) throws {
        switch container(of: url) {
        case .flac: try FLACFile(url: url).replaceComments(with: snapshot, in: url)
        case .chunks: try ChunkFile(url: url).replaceTag(with: snapshot, in: url)
        case nil: throw TagWriteError.unsupported
        }
    }
}

// MARK: - Rewriting

/// 新檔案由兩種片段組成：新產生的位元組，以及原檔保留下來的範圍
private enum Segment {
    case bytes(Data)
    case source(Range<UInt64>)
}

private enum FileRewriter {
    private static let bufferSize = 1 << 20

    static func replace(_ url: URL, with segments: [Segment]) throws {
        let fileManager = FileManager.default
        // 隱藏檔不會被掃描到；副檔名要留著，下面才讀得出來
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".lc-tmp-\(UUID().uuidString).\(url.pathExtension)")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fileManager.removeItem(at: temporary) }

        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            for segment in segments {
                switch segment {
                case .bytes(let data): try output.write(contentsOf: data)
                case .source(let range):
                    try forEachBlock(of: source, in: range) { try output.write(contentsOf: $0) }
                }
            }
            try output.synchronize()
            try output.close()
        }
        catch {
            try? output.close()
            throw error
        }

        try verify(temporary, against: source, segments: segments)
        let original = try LibraryInspector.inspect(url: url)
        let written = try LibraryInspector.inspect(url: temporary)
        guard written.sampleRate == original.sampleRate, written.bitsPerSample == original.bitsPerSample,
              written.frameCount == original.frameCount else { throw TagWriteError.verificationFailed }

        try copyAttributes(from: url, to: temporary)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// 保留下來的每一段都要和原檔完全相同，包含整段音訊
    private static func verify(_ temporary: URL, against source: FileHandle, segments: [Segment]) throws {
        let written = try FileHandle(forReadingFrom: temporary)
        defer { try? written.close() }
        for segment in segments {
            switch segment {
            case .bytes(let data):
                guard try written.read(upToCount: data.count) ?? Data() == data else { throw TagWriteError.verificationFailed }
            case .source(let range):
                try forEachBlock(of: source, in: range) { block in
                    guard try written.read(upToCount: block.count) == block else { throw TagWriteError.verificationFailed }
                }
            }
        }
        guard try written.read(upToCount: 1)?.isEmpty ?? true else { throw TagWriteError.verificationFailed }
    }

    private static func forEachBlock(of handle: FileHandle, in range: Range<UInt64>, body: (Data) throws -> Void) throws {
        guard !range.isEmpty else { return }
        try handle.seek(toOffset: range.lowerBound)
        var remaining = range.count
        while remaining > 0 {
            try autoreleasepool {
                guard let block = try handle.read(upToCount: min(remaining, bufferSize)), !block.isEmpty else {
                    throw TagWriteError.malformed
                }
                try body(block)
                remaining -= block.count
            }
        }
    }

    /// 「最近加入」看的是修改時間，寫標籤不能讓舊專輯跑到最前面
    private static func copyAttributes(from url: URL, to temporary: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard copyfile(url.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.setAttributes(attributes.filter { $0.key == .creationDate || $0.key == .modificationDate },
                                              ofItemAtPath: temporary.path)
    }
}

// MARK: - FLAC

private struct FLACFile {
    private struct Block {
        let type: UInt8
        /// 不含 4 位元組的區塊標頭
        let payload: Range<UInt64>

        var length: UInt64 { payload.upperBound - payload.lowerBound }
    }

    private enum Part {
        case bytes(Data)
        case source(Range<UInt64>)

        var length: UInt64 {
            switch self {
            case .bytes(let data): return UInt64(data.count)
            case .source(let range): return range.upperBound - range.lowerBound
            }
        }
    }

    private static let streamInfoType: UInt8 = 0
    private static let paddingType: UInt8 = 1
    private static let commentType: UInt8 = 4
    private static let headerLength: UInt64 = 4
    private static let maxBlockLength: UInt64 = 0xFFFFFF
    /// 補白放不下時整段音訊都要往後移，多留一點，下次就不用再移
    private static let defaultPadding: UInt64 = 8192

    private let start: UInt64
    private let blocks: [Block]
    private let audioStart: UInt64
    private let size: UInt64
    let comments: Data?

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        size = try handle.seekToEnd()
        guard let start = FLACHeader.metadataOffset(in: handle) else { throw TagWriteError.malformed }
        self.start = start

        var offset = start + 4
        var blocks = [Block]()
        var comments: Data?
        var isLast = false
        while !isLast {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: Int(Self.headerLength)), header.count == Int(Self.headerLength) else {
                throw TagWriteError.malformed
            }
            let bytes = [UInt8](header)
            isLast = bytes[0] & 0x80 != 0
            let length = UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let payload = (offset + Self.headerLength)..<(offset + Self.headerLength + length)
            guard payload.upperBound <= size else { throw TagWriteError.malformed }
            let block = Block(type: bytes[0] & 0x7F, payload: payload)
            if block.type == Self.commentType, comments == nil {
                guard let body = try handle.read(upToCount: Int(length)), body.count == Int(length) else { throw TagWriteError.malformed }
                comments = body
            }
            blocks.append(block)
            offset = payload.upperBound
        }
        guard blocks.first?.type == Self.streamInfoType else { throw TagWriteError.malformed }
        self.blocks = blocks
        audioStart = offset
        self.comments = comments
    }

    func replaceComments(with block: Data?, in url: URL) throws {
        if let block, UInt64(block.count) > Self.maxBlockLength { throw TagWriteError.tooLarge }

        var parts = [(type: UInt8, part: Part)]()
        var didPlaceComments = false
        for existing in blocks where existing.type != Self.paddingType {
            if existing.type == Self.commentType {
                if !didPlaceComments, let block { parts.append((Self.commentType, .bytes(block))) }
                didPlaceComments = true
            }
            else {
                parts.append((existing.type, .source(existing.payload)))
            }
        }
        if !didPlaceComments, let block { parts.insert((Self.commentType, .bytes(block)), at: 1) }

        // 讓整段中繼資料維持原本的長度，音訊就不必搬動位置
        let available = audioStart - (start + 4)
        let used = parts.reduce(UInt64(0)) { $0 + Self.headerLength + $1.part.length }
        var padding: UInt64?
        if available >= used + Self.headerLength, available - used - Self.headerLength <= Self.maxBlockLength {
            padding = available - used - Self.headerLength
        }
        else if available != used {
            padding = Self.defaultPadding
        }
        if let padding { parts.append((Self.paddingType, .bytes(Data(count: Int(padding))))) }

        var segments: [Segment] = [.source(0..<(start + 4))]
        for (index, entry) in parts.enumerated() {
            let flag: UInt8 = index == parts.count - 1 ? 0x80 : 0
            let length = entry.part.length
            segments.append(.bytes(Data([entry.type | flag, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])))
            switch entry.part {
            case .bytes(let data): segments.append(.bytes(data))
            case .source(let range): segments.append(.source(range))
            }
        }
        segments.append(.source(audioStart..<size))
        try FileRewriter.replace(url, with: segments)
    }
}

/// 只動要更新的欄位。其他欄位（ISRC、ReplayGain、版權等）與不是 UTF-8 的內容都保留原始位元組
private struct VorbisComments {
    private var vendor: Data
    private var entries: [Data]

    init(block: Data?) throws {
        guard let block else {
            vendor = Data("LosslessCompanion".utf8)
            entries = []
            return
        }
        let bytes = [UInt8](block)
        var offset = 0

        func length() throws -> Int {
            guard offset + 4 <= bytes.count else { throw TagWriteError.malformed }
            let value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            offset += 4
            return value
        }
        func field() throws -> Data {
            let count = try length()
            guard count >= 0, offset + count <= bytes.count else { throw TagWriteError.malformed }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }

        vendor = try field()
        let count = try length()
        entries = []
        entries.reserveCapacity(min(count, bytes.count))
        for _ in 0..<count { entries.append(try field()) }
    }

    var encoded: Data {
        var data = Data()
        data.append(Self.littleEndian(vendor.count))
        data.append(vendor)
        data.append(Self.littleEndian(entries.count))
        for entry in entries {
            data.append(Self.littleEndian(entry.count))
            data.append(entry)
        }
        return data
    }

    mutating func apply(_ update: TagUpdate) {
        if let title = update.title { set("TITLE", title) }
        if let artist = update.artist { set("ARTIST", artist) }
        if let albumArtist = update.albumArtist {
            set("ALBUMARTIST", albumArtist)
            if value(of: "ALBUM ARTIST") != nil { set("ALBUM ARTIST", albumArtist) }
        }
        if let album = update.album { set("ALBUM", album) }
        if let number = update.trackNumber { set("TRACKNUMBER", TagUpdate.numbered(number, keeping: value(of: "TRACKNUMBER") ?? "")) }
        if let number = update.discNumber { set("DISCNUMBER", TagUpdate.numbered(number, keeping: value(of: "DISCNUMBER") ?? "")) }
        if let genre = update.genre { set("GENRE", genre) }
        if let composer = update.composer { set("COMPOSER", composer) }
        if let year = update.year {
            set("DATE", String(year))
            if value(of: "YEAR") != nil { set("YEAR", String(year)) }
        }
    }

    private func isEntry(_ entry: Data, named key: String) -> Bool {
        guard let separator = entry.firstIndex(of: UInt8(ascii: "=")) else { return false }
        return String(decoding: entry[entry.startIndex..<separator], as: UTF8.self).uppercased() == key
    }

    private func value(of key: String) -> String? {
        entries.first { isEntry($0, named: key) }.flatMap { entry in
            entry.firstIndex(of: UInt8(ascii: "=")).map { String(decoding: entry[entry.index(after: $0)...], as: UTF8.self) }
        }
    }

    /// 同一個欄位可能有多筆，留下第一個位置放新值，其餘移除，讀的時候才不會還有舊資料
    private mutating func set(_ key: String, _ value: String) {
        let entry = Data("\(key)=\(value)".utf8)
        guard let first = entries.firstIndex(where: { isEntry($0, named: key) }) else {
            entries.append(entry)
            return
        }
        entries[first] = entry
        entries = entries.enumerated().filter { $0.offset <= first || !isEntry($0.element, named: key) }.map(\.element)
    }

    private static func littleEndian(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }
}

// MARK: - WAV and AIFF

/// 這兩種格式由一塊塊區塊組成，只換 ID3 那一塊，bext、iXML、cue 等其他區塊都不碰
private struct ChunkFile {
    private static let formHeaderLength: UInt64 = 12
    private static let chunkHeaderLength: UInt64 = 8
    private static let unknownSize: UInt64 = 0xFFFFFFFF

    private let form: Data
    private let isBigEndian: Bool
    private let size: UInt64
    /// 包含區塊標頭與補齊的位元組
    private let tagRange: Range<UInt64>?
    /// 兩種寫法都有：id3 與 ID3，已經有區塊時沿用原本的
    private let tagID: Data
    /// 最後一塊是奇數長度又沒有補齊，後面要接新區塊時得補上
    private let endsUnaligned: Bool
    let tag: Data?

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Int(Self.formHeaderLength)), header.count == Int(Self.formHeaderLength) else {
            throw TagWriteError.malformed
        }
        form = header
        let formID = String(decoding: header.prefix(4), as: UTF8.self)
        let formType = String(decoding: header.suffix(4), as: UTF8.self)
        guard (formID == "RIFF" && formType == "WAVE") || (formID == "FORM" && (formType == "AIFF" || formType == "AIFC")) else {
            throw TagWriteError.malformed
        }
        isBigEndian = formID == "FORM"

        var offset = Self.formHeaderLength
        var tagRange: Range<UInt64>?
        var tag: Data?
        var actualID: Data?
        while offset + Self.chunkHeaderLength <= size {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(Self.chunkHeaderLength)), chunk.count == Int(Self.chunkHeaderLength) else {
                throw TagWriteError.malformed
            }
            let bytes = [UInt8](chunk)
            let sizeBytes = isBigEndian ? Array(bytes[4..<8]) : Array(bytes[4..<8].reversed())
            let length = sizeBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard length != Self.unknownSize, offset + Self.chunkHeaderLength + length <= size else { throw TagWriteError.malformed }

            let next = offset + Self.chunkHeaderLength + length + length % 2
            if tagRange == nil, String(decoding: bytes[0..<4], as: UTF8.self).lowercased() == "id3 " {
                guard let body = try handle.read(upToCount: Int(length)), body.count == Int(length) else { throw TagWriteError.malformed }
                tag = body
                tagRange = offset..<min(next, size)
                actualID = chunk.prefix(4)
            }
            offset = next
        }
        // 區塊沒有剛好排滿檔案，代表結構和想的不同，不要動它
        guard offset == size || offset == size + 1 else { throw TagWriteError.malformed }
        endsUnaligned = offset == size + 1
        self.tagRange = tagRange
        self.tag = tag
        tagID = actualID ?? Data((isBigEndian ? "ID3 " : "id3 ").utf8)
    }

    func replaceTag(with tag: Data?, in url: URL) throws {
        var body = [Segment]()
        let chunk = tag.map(encodedChunk).map(Segment.bytes)
        if let tagRange {
            body.append(.source(Self.formHeaderLength..<tagRange.lowerBound))
            if let chunk { body.append(chunk) }
            body.append(.source(tagRange.upperBound..<size))
        }
        else {
            body.append(.source(Self.formHeaderLength..<size))
            if endsUnaligned { body.append(.bytes(Data([0]))) }
            if let chunk { body.append(chunk) }
        }

        let length = body.reduce(UInt64(0)) { total, segment in
            switch segment {
            case .bytes(let data): return total + UInt64(data.count)
            case .source(let range): return total + (range.upperBound - range.lowerBound)
            }
        }
        // 表頭記的大小不含前 8 個位元組，後面還有 4 個位元組的格式名稱
        let declared = length + 4
        guard declared < Self.unknownSize else { throw TagWriteError.tooLarge }

        var header = form
        header.replaceSubrange(header.startIndex.advanced(by: 4)..<header.startIndex.advanced(by: 8), with: sizeBytes(declared))
        try FileRewriter.replace(url, with: [.bytes(header)] + body)
    }

    private func encodedChunk(_ tag: Data) -> Data {
        var data = tagID
        data.append(sizeBytes(UInt64(tag.count)))
        data.append(tag)
        if tag.count % 2 == 1 { data.append(0) }
        return data
    }

    private func sizeBytes(_ value: UInt64) -> Data {
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return Data(isBigEndian ? bytes : bytes.reversed())
    }
}
