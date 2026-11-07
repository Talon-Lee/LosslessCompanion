//
//  AlbumExporter.swift
//  LosslessCompanion
//
//  把目前頁面的專輯打包成一個 ZIP。無損音檔幾乎壓不下去，所以只封存不壓縮，音檔內容和原檔完全相同。
//  自己寫 ZIP 才能回報進度、中途取消，名稱也能標成 UTF-8，日文歌名在 Windows 解開才不會亂碼。
//

import Combine
import Foundation
import zlib

enum ExportItem: Equatable {
    case file(URL)
    case text(Data)
}

struct ExportEntry: Equatable {
    /// ZIP 裡的路徑
    let path: String
    let item: ExportItem
    let size: UInt64
}

enum ExportError: LocalizedError, Equatable {
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let needed = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
            return String(localized: "目的地空間不足：需要 \(needed)，只剩 \(available)")
        case .cancelled:
            return String(localized: "已取消")
        }
    }
}

enum ExportPlanner {
    static let playCountFileName = String(localized: "播放次數.csv")

    private static let sidecarExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "tif", "tiff", "pdf"]

    static func entries(for albums: [AlbumGroup], playCounts: [String: PlayRecord]) -> [ExportEntry] {
        var entries = [ExportEntry]()
        var used = Set<String>()
        var rows = [String]()

        for album in albums {
            let folder = uniqueName(FileNamer.sanitized("\(album.artist) - \(album.title)"), in: &used)
            var names = Set<String>()
            var sidecarFolders = [String]()

            for track in album.tracks {
                let path = uniqueName(folder + "/" + relativePath(of: track, in: album), in: &names)
                entries.append(ExportEntry(path: path, item: .file(track.url), size: fileSize(track.url)))
                let record = playCounts[track.path]
                rows.append([album.artist, album.title, track.title, path, String(record?.count ?? 0),
                             record.map { ISO8601DateFormatter().string(from: $0.lastPlayed) } ?? ""]
                    .map(csvField).joined(separator: ","))
                if !sidecarFolders.contains(track.folder) { sidecarFolders.append(track.folder) }
            }

            // 封面與小冊子跟著走；資料夾裡其他東西可能和這張專輯無關
            for source in sidecarFolders {
                let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil,
                                                                          options: .skipsHiddenFiles)) ?? []
                for file in files.sorted(by: { $0.path < $1.path }) where sidecarExtensions.contains(file.pathExtension.lowercased()) {
                    let relative = source.hasPrefix(album.id + "/") ? String(source.dropFirst(album.id.count + 1)) + "/" : ""
                    let path = uniqueName(folder + "/" + relative + file.lastPathComponent, in: &names)
                    entries.append(ExportEntry(path: path, item: .file(file), size: fileSize(file)))
                }
            }
        }

        // 加 BOM，Excel 才認得這是 UTF-8
        let header = String(localized: "歌手,專輯,歌名,檔案,播放次數,上次播放")
        let csv = Data([0xEF, 0xBB, 0xBF]) + Data(([header] + rows).joined(separator: "\r\n").utf8) + Data("\r\n".utf8)
        entries.append(ExportEntry(path: playCountFileName, item: .text(csv), size: UInt64(csv.count)))
        return entries
    }

    /// 專輯資料夾底下保留原本的子資料夾，合併來的其他資料夾放在自己的名稱底下
    private static func relativePath(of track: LibraryTrack, in album: AlbumGroup) -> String {
        if track.path.hasPrefix(album.id + "/") { return String(track.path.dropFirst(album.id.count + 1)) }
        return URL(fileURLWithPath: track.folder).lastPathComponent + "/" + track.url.lastPathComponent
    }

    private static func uniqueName(_ path: String, in used: inout Set<String>) -> String {
        if used.insert(FileNamer.identity(path)).inserted { return path }
        let url = URL(fileURLWithPath: "/" + path)
        let stem = String(url.deletingPathExtension().path.dropFirst())
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var number = 2
        while !used.insert(FileNamer.identity("\(stem) \(number)\(suffix)")).inserted { number += 1 }
        return "\(stem) \(number)\(suffix)"
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { ",\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init) ?? 0
    }
}

/// 只寫 Stored 模式。超過 4 GB 的檔案、位置或超過 65535 個項目時改用 Zip64
final class ZipWriter {
    private struct Central {
        let name: Data
        let crc: UInt32
        let size: UInt64
        let offset: UInt64
        let time: UInt16
        let date: UInt16
    }

    private static let bufferSize = 1 << 20
    private static let limit32: UInt64 = 0xFFFFFFFF
    private static let limit16 = 0xFFFF
    private static let utf8Flag: UInt16 = 0x0800
    private static let versionPlain: UInt16 = 20
    private static let versionZip64: UInt16 = 45
    private static let madeByUnix: UInt16 = 0x0300
    private static let regularFile: UInt32 = 0o100644

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = [Central]()

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    /// onBytes 回傳 false 時中止
    func add(path: String, file url: URL, size: UInt64, modified: Date, onBytes: (Int) -> Bool) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        try addEntry(path: path, size: size, modified: modified) { write in
            var remaining = size
            while remaining > 0 {
                let keepGoing: Bool = try autoreleasepool {
                    guard let block = try source.read(upToCount: min(Self.bufferSize, Int(clamping: remaining))), !block.isEmpty else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    try write(block)
                    remaining -= UInt64(block.count)
                    return onBytes(block.count)
                }
                if !keepGoing { throw ExportError.cancelled }
            }
        }
    }

    func add(path: String, data: Data, modified: Date) throws {
        try addEntry(path: path, size: UInt64(data.count), modified: modified) { try $0(data) }
    }

    private func addEntry(path: String, size: UInt64, modified: Date, body: ((Data) throws -> Void) throws -> Void) throws {
        let name = Data(path.precomposedStringWithCanonicalMapping.utf8)
        let (time, date) = Self.dosDate(modified)
        let needsZip64 = size >= Self.limit32
        let start = offset

        var header = Data()
        header.appendLE(UInt32(0x04034B50))
        header.appendLE(needsZip64 ? Self.versionZip64 : Self.versionPlain)
        header.appendLE(Self.utf8Flag)
        header.appendLE(UInt16(0))
        header.appendLE(time)
        header.appendLE(date)
        let crcPosition = UInt64(header.count)
        header.appendLE(UInt32(0))
        header.appendLE(UInt32(min(size, Self.limit32)))
        header.appendLE(UInt32(min(size, Self.limit32)))
        header.appendLE(UInt16(name.count))
        header.appendLE(UInt16(needsZip64 ? 20 : 0))
        header.append(name)
        if needsZip64 {
            header.appendLE(UInt16(1))
            header.appendLE(UInt16(16))
            header.appendLE(size)
            header.appendLE(size)
        }
        try write(header)

        var crc = UInt32(zlib.crc32(0, nil, 0))
        try body { block in
            crc = block.withUnsafeBytes { buffer in
                UInt32(zlib.crc32(uLong(crc), buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
            }
            try self.write(block)
        }

        // 長度事先就知道，校驗碼要讀完才有，回頭補上
        try handle.seek(toOffset: start + crcPosition)
        var patch = Data()
        patch.appendLE(crc)
        try handle.write(contentsOf: patch)
        try handle.seek(toOffset: offset)

        central.append(Central(name: name, crc: crc, size: size, offset: start, time: time, date: date))
    }

    func finish() throws {
        let directoryStart = offset
        for entry in central { try write(centralRecord(entry)) }
        let directorySize = offset - directoryStart

        let needsZip64 = central.count >= Self.limit16 || directoryStart >= Self.limit32 || directorySize >= Self.limit32
        if needsZip64 {
            let recordStart = offset
            var record = Data()
            record.appendLE(UInt32(0x06064B50))
            record.appendLE(UInt64(44))
            record.appendLE(Self.madeByUnix | Self.versionZip64)
            record.appendLE(Self.versionZip64)
            record.appendLE(UInt32(0))
            record.appendLE(UInt32(0))
            record.appendLE(UInt64(central.count))
            record.appendLE(UInt64(central.count))
            record.appendLE(directorySize)
            record.appendLE(directoryStart)
            record.appendLE(UInt32(0x07064B50))
            record.appendLE(UInt32(0))
            record.appendLE(recordStart)
            record.appendLE(UInt32(1))
            try write(record)
        }

        var end = Data()
        end.appendLE(UInt32(0x06054B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(min(central.count, Self.limit16)))
        end.appendLE(UInt16(min(central.count, Self.limit16)))
        end.appendLE(UInt32(min(directorySize, Self.limit32)))
        end.appendLE(UInt32(min(directoryStart, Self.limit32)))
        end.appendLE(UInt16(0))
        try write(end)
        try handle.synchronize()
    }

    private func centralRecord(_ entry: Central) -> Data {
        var extra = Data()
        if entry.size >= Self.limit32 {
            extra.appendLE(entry.size)
            extra.appendLE(entry.size)
        }
        if entry.offset >= Self.limit32 { extra.appendLE(entry.offset) }
        let usesZip64 = !extra.isEmpty

        var record = Data()
        record.appendLE(UInt32(0x02014B50))
        record.appendLE(Self.madeByUnix | Self.versionZip64)
        record.appendLE(usesZip64 ? Self.versionZip64 : Self.versionPlain)
        record.appendLE(Self.utf8Flag)
        record.appendLE(UInt16(0))
        record.appendLE(entry.time)
        record.appendLE(entry.date)
        record.appendLE(entry.crc)
        record.appendLE(UInt32(min(entry.size, Self.limit32)))
        record.appendLE(UInt32(min(entry.size, Self.limit32)))
        record.appendLE(UInt16(entry.name.count))
        record.appendLE(UInt16(usesZip64 ? extra.count + 4 : 0))
        record.appendLE(UInt16(0))
        record.appendLE(UInt16(0))
        record.appendLE(UInt16(0))
        record.appendLE(Self.regularFile << 16)
        record.appendLE(UInt32(min(entry.offset, Self.limit32)))
        record.append(entry.name)
        if usesZip64 {
            record.appendLE(UInt16(1))
            record.appendLE(UInt16(extra.count))
            record.append(extra)
        }
        return record
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private static func dosDate(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = (parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2
        let day = max((parts.year ?? 1980) - 1980, 0) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }
}

private extension Data {
    mutating func appendLE<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// 回呼都在主執行緒
final class ExportJob: ObservableObject {
    enum State: Equatable {
        case ready
        case running
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state = State.ready
    @Published private(set) var fraction = 0.0

    let entries: [ExportEntry]
    let totalSize: UInt64

    private let cancelLock = NSLock()
    private var isCancelled = false

    init(entries: [ExportEntry]) {
        self.entries = entries
        totalSize = entries.reduce(0) { $0 + $1.size }
    }

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }

    private var shouldContinue: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return !isCancelled
    }

    func start(destination: URL) {
        state = .running
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try write(to: destination)
                DispatchQueue.main.async { self.state = .finished(destination) }
            }
            catch ExportError.cancelled {
                DispatchQueue.main.async { self.state = .ready; self.fraction = 0 }
            }
            catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func write(to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, UInt64(max(available, 0)) < totalSize {
            throw ExportError.notEnoughSpace(needed: totalSize, available: UInt64(max(available, 0)))
        }

        // 寫完才換上正式檔名，中途失敗時不會留下看似完整的 ZIP，也不會弄壞同名的舊檔
        let partial = folder.appendingPathComponent(".\(destination.lastPathComponent).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        let writer = try ZipWriter(url: partial)
        var written: UInt64 = 0
        var lastReported = Date.distantPast

        for entry in entries {
            switch entry.item {
            case .file(let url):
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                try writer.add(path: entry.path, file: url, size: entry.size, modified: modified ?? Date()) { count in
                    written += UInt64(count)
                    let now = Date()
                    if now.timeIntervalSince(lastReported) > 0.1 {
                        lastReported = now
                        let fraction = Double(written) / Double(max(totalSize, 1))
                        DispatchQueue.main.async { self.fraction = fraction }
                    }
                    return shouldContinue
                }
            case .text(let data):
                try writer.add(path: entry.path, data: data, modified: Date())
            }
        }
        try writer.finish()
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
    }
}
