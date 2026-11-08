//
//  InboxConverter.swift
//  LosslessCompanion
//
//  收件匣的轉檔：ALAC 的 m4a 轉成 FLAC，逐樣本比對過才算完成。
//  流程參考 NexTags（MIT，https://github.com/lumakes-apps/NexTags）的匯入步驟，
//  改用 macOS 內建的 afconvert，不需要另外安裝 ffmpeg。
//

import AudioToolbox
import Foundation

enum InboxCodec: Equatable {
    case alac
    case flac
    case pcm
    case lossy(String)
    case unknown
}

enum InboxConvertError: LocalizedError, Equatable {
    case encoderFailed(String)
    case mismatch
    case cannotVerify(String)

    var errorDescription: String? {
        switch self {
        case .encoderFailed(let detail): return String(localized: "轉檔失敗：\(detail)")
        case .mismatch: return String(localized: "轉出的 FLAC 和原檔不一致，已保留原檔")
        case .cannotVerify(let detail): return String(localized: "無法比對轉檔結果：\(detail)")
        }
    }
}

enum InboxConverter {
    static func codec(of url: URL) -> InboxCodec {
        guard let format = dataFormat(of: url) else { return .unknown }
        switch format.mFormatID {
        case kAudioFormatAppleLossless: return .alac
        case kAudioFormatFLAC: return .flac
        case kAudioFormatLinearPCM: return .pcm
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            return .lossy("AAC")
        case kAudioFormatMPEGLayer3: return .lossy("MP3")
        default: return .unknown
        }
    }

    static func duration(of url: URL) -> TimeInterval {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return 0 }
        defer { AudioFileClose(file) }
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout.size(ofValue: seconds))
        guard AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &seconds) == noErr else { return 0 }
        return seconds
    }

    private static func dataFormat(of url: URL) -> AudioStreamBasicDescription? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr else { return nil }
        return format
    }

    /// 把 ALAC 轉成同樣位元深度的 FLAC，標籤、歌詞與封面一起帶過去。
    /// 轉出的檔案先放在 output，和原檔逐樣本比對一致才回傳
    static func convertALAC(_ source: URL, to output: URL) throws {
        guard let format = dataFormat(of: source), format.mFormatID == kAudioFormatAppleLossless else {
            throw InboxConvertError.encoderFailed(String(localized: "不是 ALAC"))
        }
        try? FileManager.default.removeItem(at: output)
        // 不指定時 afconvert 一律寫成 24-bit，16-bit 的歌會被當成 24-bit 播放；
        // FLAC 和 ALAC 的位元深度旗標是同一組數值，直接沿用
        try run("/usr/bin/afconvert", ["-f", "flac", "-d", "flac/\(format.mFormatFlags)", source.path, output.path])
        do {
            try FLACMetadataWriter.rewrite(output, comments: comments(from: source), picture: MP4Atoms.coverArt(in: source))
            try verifyIdentical(source, output)
        }
        catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// 原檔的標籤原樣帶到 FLAC；之後由收件匣依 Apple Music 的資料再更新
    static func comments(from source: URL) -> [(String, String)] {
        let tags = TrackMetadata.tags(for: source, fillingGaps: false)
        var comments = [(String, String)]()
        func add(_ key: String, _ value: String) {
            if !value.isEmpty { comments.append((key, value)) }
        }
        add("TITLE", tags.title)
        add("ARTIST", tags.artist)
        add("ALBUMARTIST", tags.albumArtist)
        add("ALBUM", tags.album)
        if tags.trackNumber > 0 { add("TRACKNUMBER", String(tags.trackNumber)) }
        if tags.discNumber > 0 { add("DISCNUMBER", String(tags.discNumber)) }
        add("GENRE", tags.genre)
        add("COMPOSER", tags.composer)
        if tags.year > 0 { add("DATE", String(tags.year)) }
        if tags.isCompilation { add("COMPILATION", "1") }
        add("COPYRIGHT", MP4Atoms.text(MP4Atoms.copyrightAtom, in: source) ?? "")
        add("LYRICS", MP4Atoms.text(MP4Atoms.lyricsAtom, in: source) ?? "")
        return comments
    }

    /// 兩個檔案解碼後的每個樣本都要相同，長度、取樣率與位元深度也要一樣
    static func verifyIdentical(_ lhs: URL, _ rhs: URL) throws {
        let left: PCMFileReader
        let right: PCMFileReader
        do {
            left = try PCMFileReader(url: lhs)
            right = try PCMFileReader(url: rhs)
        }
        catch {
            throw InboxConvertError.cannotVerify(error.localizedDescription)
        }
        guard left.format == right.format else { throw InboxConvertError.mismatch }

        let frames = 65536
        let a = UnsafeMutablePointer<Int32>.allocate(capacity: frames * 2)
        let b = UnsafeMutablePointer<Int32>.allocate(capacity: frames * 2)
        defer {
            a.deallocate()
            b.deallocate()
        }
        var total: Int64 = 0
        while true {
            let countA = try fill(left, a, frames)
            let countB = try fill(right, b, frames)
            guard countA == countB else { throw InboxConvertError.mismatch }
            if countA == 0 { break }
            guard memcmp(a, b, countA * 8) == 0 else { throw InboxConvertError.mismatch }
            total += Int64(countA)
        }
        guard total == left.format.frameCount else { throw InboxConvertError.mismatch }
    }

    private static func fill(_ reader: PCMFileReader, _ buffer: UnsafeMutablePointer<Int32>, _ frames: Int) throws -> Int {
        var total = 0
        while total < frames {
            let count = try reader.read(into: buffer + total * 2, frames: frames - total)
            if count == 0 { break }
            total += count
        }
        return total
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() }
        catch { throw InboxConvertError.encoderFailed(error.localizedDescription) }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw InboxConvertError.encoderFailed(text.isEmpty ? "afconvert \(process.terminationStatus)" : text)
        }
    }
}

/// 只用在剛轉出、還沒有人用過的 FLAC：重寫整段中繼資料，換上標籤與封面，音訊原樣接在後面
enum FLACMetadataWriter {
    private static let streamInfoType: UInt8 = 0
    private static let paddingType: UInt8 = 1
    private static let commentType: UInt8 = 4
    private static let pictureType: UInt8 = 6
    private static let maxBlockLength = (1 << 24) - 1
    private static let padding = 8192

    static func rewrite(_ url: URL, comments: [(String, String)], picture: Data?) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let start = FLACHeader.metadataOffset(in: handle) else { throw TagWriteError.malformed }

        var kept = [(type: UInt8, body: Data)]()
        var offset = start + 4
        var isLast = false
        while !isLast {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { throw TagWriteError.malformed }
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard let body = try handle.read(upToCount: length), body.count == length else { throw TagWriteError.malformed }
            if ![paddingType, commentType, pictureType].contains(type) { kept.append((type, body)) }
            offset += 4 + UInt64(length)
        }
        guard kept.first?.type == streamInfoType else { throw TagWriteError.malformed }

        kept.append((commentType, commentBlock(comments)))
        if let picture, let block = pictureBlock(picture), block.count <= maxBlockLength {
            kept.append((pictureType, block))
        }
        kept.append((paddingType, Data(count: padding)))

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".lc-tagging-\(UUID().uuidString).flac")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try output.write(contentsOf: Data("fLaC".utf8))
            for (index, block) in kept.enumerated() {
                guard block.body.count <= maxBlockLength else { throw TagWriteError.tooLarge }
                let flag: UInt8 = index == kept.count - 1 ? 0x80 : 0
                try output.write(contentsOf: Data([flag | block.type, UInt8(block.body.count >> 16 & 0xFF),
                                                   UInt8(block.body.count >> 8 & 0xFF), UInt8(block.body.count & 0xFF)]))
                try output.write(contentsOf: block.body)
            }
            try handle.seek(toOffset: offset)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        }
        catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    static func commentBlock(_ comments: [(String, String)]) -> Data {
        var data = Data()
        let vendor = Data("LosslessCompanion".utf8)
        data.append(littleEndian(vendor.count))
        data.append(vendor)
        data.append(littleEndian(comments.count))
        for (key, value) in comments {
            let entry = Data("\(key)=\(value)".utf8)
            data.append(littleEndian(entry.count))
            data.append(entry)
        }
        return data
    }

    /// 類型 3 是封面，寬高留 0，播放器會自己從圖片讀
    static func pictureBlock(_ image: Data) -> Data? {
        guard let mime = mimeType(of: image) else { return nil }
        var data = Data()
        data.append(bigEndian(3))
        data.append(bigEndian(mime.utf8.count))
        data.append(Data(mime.utf8))
        data.append(bigEndian(0))
        for _ in 0..<4 { data.append(bigEndian(0)) }
        data.append(bigEndian(image.count))
        data.append(image)
        return data
    }

    static func mimeType(of image: Data) -> String? {
        if image.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if image.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return nil
    }

    private static func littleEndian(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private static func bigEndian(_ value: Int) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
