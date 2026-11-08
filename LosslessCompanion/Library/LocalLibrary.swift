//
//  LocalLibrary.swift
//  LosslessCompanion
//
//  本地音樂庫：掃描、驗證、搜尋。只有能以 Bit-Perfect 方式播放的檔案會進入檢索結果，
//  有損、DSD、多聲道、損毀，或目前 DAC 不支援的規格一律隱藏。
//

import AudioToolbox
import Combine
import Foundation

// MARK: - Model

struct LibraryTrack: Codable, Hashable, Identifiable {
    var path: String
    let title: String
    var artist: String
    let album: String
    let trackNumber: Int
    var discNumber: Int
    let sampleRate: Double
    let bitsPerSample: Int
    let frameCount: Int64
    let titleKey: String
    var artistKey: String
    var searchKey: String
    var albumArtist: String? = nil
    var genre: String? = nil
    var composer: String? = nil
    var year: Int? = nil
    var isCompilation: Bool? = nil
    /// 舊索引沒有上面這些標籤，版本不同時只重讀標籤，不必重新檢查音訊
    var tagVersion: Int? = nil

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var folder: String { url.deletingLastPathComponent().path }
    var duration: TimeInterval { Double(frameCount) / sampleRate }

    var format: AudioSourceFormat {
        AudioSourceFormat(sampleRate: sampleRate, bitsPerSample: bitsPerSample, channels: 2, frameCount: frameCount)
    }

    /// 舊索引的歌手與搜尋字串也可能少了資料，一起更新，音訊不必重新檢查
    func updating(with tags: TrackTags) -> LibraryTrack {
        var copy = self
        copy.artist = tags.artist.isEmpty ? tags.albumArtist : tags.artist
        copy.artistKey = SearchText.normalize(copy.artist)
        copy.discNumber = tags.discNumber
        copy.searchKey = searchKey(title: tags.title, artist: tags.artist, albumArtist: tags.albumArtist, album: tags.album)
        copy.albumArtist = tags.albumArtist.isEmpty ? nil : tags.albumArtist
        copy.genre = tags.genre.isEmpty ? nil : tags.genre
        copy.composer = tags.composer.isEmpty ? nil : tags.composer
        copy.year = tags.year == 0 ? nil : tags.year
        copy.isCompilation = tags.isCompilation
        copy.tagVersion = TrackMetadata.version
        return copy
    }

    /// 搜尋也找得到檔名與資料夾，路徑改變時要跟著更新
    func moved(to path: String) -> LibraryTrack {
        var copy = self
        copy.path = path
        copy.searchKey = copy.searchKey(title: title, artist: artist, albumArtist: albumArtist ?? "", album: album)
        return copy
    }

    private func searchKey(title: String, artist: String, albumArtist: String, album: String) -> String {
        let parent = url.deletingLastPathComponent()
        let keywords = [title, artist, albumArtist, album,
                        url.deletingPathExtension().lastPathComponent,
                        parent.lastPathComponent,
                        parent.deletingLastPathComponent().lastPathComponent]
        return SearchText.normalize(keywords.joined(separator: "\n"))
    }
}

private struct LibraryCacheEntry: Codable {
    let path: String
    let size: Int64
    let modified: Double
    let track: LibraryTrack?
    let rejection: String?

    func moved(to path: String) -> LibraryCacheEntry {
        LibraryCacheEntry(path: path, size: size, modified: modified, track: track?.moved(to: path), rejection: rejection)
    }

    /// 掃描時大小與時間對不上就會重新檢查，曲目在那之前照常顯示
    var outdated: LibraryCacheEntry {
        LibraryCacheEntry(path: path, size: size, modified: -1, track: track, rejection: rejection)
    }
}

// MARK: - Search normalization

enum SearchText {
    private static let toSimplified = StringTransform("Hant-Hans")

    /// 忽略大小寫、重音、全半形；繁簡與平假名片假名視為相同
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let simplified = folded.applyingTransform(toSimplified, reverse: false) ?? folded
        return simplified.applyingTransform(.hiraganaToKatakana, reverse: false) ?? simplified
    }

    static func tokens(of query: String) -> [String] {
        normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

// MARK: - Metadata

struct TrackTags {
    var title = ""
    var artist = ""
    var albumArtist = ""
    var album = ""
    var trackNumber = 0
    var discNumber = 0
    var genre = ""
    var composer = ""
    var year = 0
    var isCompilation = false
}

enum TrackMetadata {
    static let version = 4

    /// fillingGaps 為 false 時只回傳檔案裡真的有的標籤，不從檔名與資料夾推測
    static func tags(for url: URL, fillingGaps: Bool = true) -> TrackTags {
        var tags = TrackTags()
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "flac" {
            apply(vorbisComments: FLACBlocks.read(url: url).comments, to: &tags)
        }
        else {
            apply(audioFileInfo: audioFileInfo(url: url), to: &tags)
            if let tag = AudioChunks.id3Tag(in: url) { apply(id3: ID3Tag.text(in: tag), to: &tags) }
            if fileExtension == "m4a", let mp4 = MP4Atoms.tags(in: url) { apply(mp4: mp4, to: &tags) }
        }
        if fillingGaps { fillGaps(in: &tags, from: url) }
        return tags
    }

    /// 系統讀到的優先，只補空的欄位
    private static func apply(mp4: MP4Atoms.Tags, to tags: inout TrackTags) {
        if tags.title.isEmpty { tags.title = mp4.title }
        if tags.artist.isEmpty { tags.artist = mp4.artist }
        if tags.albumArtist.isEmpty { tags.albumArtist = mp4.albumArtist }
        if tags.album.isEmpty { tags.album = mp4.album }
        if tags.genre.isEmpty { tags.genre = mp4.genre }
        if tags.composer.isEmpty { tags.composer = mp4.composer }
        if tags.year == 0 { tags.year = leadingNumber(mp4.date) }
        if tags.trackNumber == 0 { tags.trackNumber = mp4.trackNumber }
        if tags.discNumber == 0 { tags.discNumber = mp4.discNumber }
        if mp4.isCompilation { tags.isCompilation = true }
    }

    /// ID3 優先：WAV 同時有 LIST 區塊時，系統讀到的可能是沒有更新過的舊資料
    private static func apply(id3 text: ID3Tag.Text, to tags: inout TrackTags) {
        tags.albumArtist = text.albumArtist
        tags.discNumber = leadingNumber(text.discNumber)
        if !text.title.isEmpty { tags.title = text.title }
        if !text.artist.isEmpty { tags.artist = text.artist }
        if !text.album.isEmpty { tags.album = text.album }
        if !text.composer.isEmpty { tags.composer = text.composer }
        if leadingNumber(text.trackNumber) > 0 { tags.trackNumber = leadingNumber(text.trackNumber) }
        if leadingNumber(text.year) > 0 { tags.year = leadingNumber(text.year) }
        // 舊標籤的類型可能是 "(17)" 這種代碼，系統讀到的已經換成名稱
        if !text.genre.isEmpty, !text.genre.hasPrefix("("), !text.genre.allSatisfy(\.isNumber) { tags.genre = text.genre }
    }

    private static func apply(vorbisComments comments: [String: String], to tags: inout TrackTags) {
        tags.title = comments["TITLE"] ?? ""
        tags.artist = comments["ARTIST"] ?? ""
        tags.albumArtist = comments["ALBUMARTIST"] ?? comments["ALBUM ARTIST"] ?? ""
        tags.album = comments["ALBUM"] ?? ""
        tags.trackNumber = leadingNumber(comments["TRACKNUMBER"])
        tags.discNumber = leadingNumber(comments["DISCNUMBER"])
        tags.genre = comments["GENRE"] ?? ""
        tags.composer = comments["COMPOSER"] ?? ""
        tags.year = leadingNumber(comments["DATE"] ?? comments["YEAR"])
        tags.isCompilation = ["1", "true"].contains(comments["COMPILATION"]?.lowercased())
    }

    private static func apply(audioFileInfo info: [String: Any], to tags: inout TrackTags) {
        tags.title = info[kAFInfoDictionary_Title] as? String ?? ""
        tags.artist = info[kAFInfoDictionary_Artist] as? String ?? ""
        tags.album = info[kAFInfoDictionary_Album] as? String ?? ""
        tags.trackNumber = leadingNumber(info[kAFInfoDictionary_TrackNumber] as? String)
        tags.genre = info[kAFInfoDictionary_Genre] as? String ?? ""
        tags.composer = info[kAFInfoDictionary_Composer] as? String ?? ""
        tags.year = leadingNumber(info[kAFInfoDictionary_Year] as? String)
    }

    private static func audioFileInfo(url: URL) -> [String: Any] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return [:] }
        defer { AudioFileClose(file) }
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr else { return [:] }
        return info?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    /// 沒有標籤的 WAV/AIFF 從路徑推測：專輯取資料夾名稱，歌名與歌手取檔名
    private static func fillGaps(in tags: inout TrackTags, from url: URL) {
        let stem = url.deletingPathExtension().lastPathComponent
        if tags.album.isEmpty { tags.album = url.deletingLastPathComponent().lastPathComponent }
        guard tags.title.isEmpty else { return }

        if let match = captures(#"^(.+?) - (\d{1,3})\.? +(.+)$"#, in: stem) {
            if tags.artist.isEmpty { tags.artist = match[0] }
            if tags.trackNumber == 0 { tags.trackNumber = Int(match[1]) ?? 0 }
            tags.title = match[2]
        }
        else if let match = captures(#"^(\d{1,3})[.\- ]+(.+)$"#, in: stem) {
            if tags.trackNumber == 0 { tags.trackNumber = Int(match[0]) ?? 0 }
            tags.title = match[1]
        }
        else if let match = captures(#"^(.+?) - (.+)$"#, in: stem) {
            if tags.artist.isEmpty { tags.artist = match[0] }
            tags.title = match[1]
        }
        else {
            tags.title = stem
        }
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func leadingNumber(_ text: String?) -> Int {
        guard let text else { return 0 }
        return Int(text.prefix(while: \.isNumber)) ?? 0
    }
}

/// 讀取 FLAC 中繼資料區塊，不解碼音訊
enum FLACBlocks {
    struct Contents {
        var comments = [String: String]()
        var picture: Data?
    }

    static func read(url: URL, includePicture: Bool = false) -> Contents {
        var contents = Contents()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return contents }
        defer { try? handle.close() }
        guard let start = FLACHeader.metadataOffset(in: handle),
              (try? handle.seek(toOffset: start + 4)) != nil else { return contents }

        var isLast = false
        while !isLast {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            isLast = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let wanted = type == 4 || (type == 6 && includePicture && contents.picture == nil)

            if wanted {
                guard let block = try? handle.read(upToCount: Int(length)) else { break }
                if type == 4 { contents.comments = parseComments(block) }
                else { contents.picture = parsePicture(block) }
            }
            else {
                guard let offset = try? handle.offset(), (try? handle.seek(toOffset: offset + length)) != nil else { break }
            }
        }
        return contents
    }

    private static func parseComments(_ block: Data) -> [String: String] {
        let bytes = [UInt8](block)
        var offset = 0

        func littleEndianLength() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            offset += 4
            return value
        }

        guard let vendor = littleEndianLength() else { return [:] }
        offset += vendor
        guard let count = littleEndianLength() else { return [:] }

        var comments = [String: String]()
        for _ in 0..<count {
            guard let length = littleEndianLength(), offset + length <= bytes.count else { break }
            let entry = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            offset += length
            if let separator = entry.firstIndex(of: "=") {
                let key = entry[..<separator].uppercased()
                if comments[key] == nil { comments[key] = String(entry[entry.index(after: separator)...]) }
            }
        }
        return comments
    }

    private static func parsePicture(_ block: Data) -> Data? {
        let bytes = [UInt8](block)
        var offset = 4

        func bigEndianLength() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            return value
        }

        guard let mime = bigEndianLength() else { return nil }
        offset += mime
        guard let description = bigEndianLength() else { return nil }
        offset += description + 16
        guard let length = bigEndianLength(), offset + length <= bytes.count else { return nil }
        return Data(bytes[offset..<(offset + length)])
    }
}

// MARK: - Inspection

enum LibraryInspector {
    /// Core Audio 能解碼且可能為無損的副檔名；其他音訊格式直接列為不可播放
    static let candidateExtensions: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "caf"]
    static let rejectedExtensions: Set<String> = ["mp3", "aac", "ogg", "oga", "opus", "wma", "dsf", "dff", "ape", "wv", "tak", "mpc"]

    private static let probeFrames = 4096

    /// 實際讀取開頭與結尾，截斷或損毀的檔案在這裡就會被擋下
    static func inspect(url: URL) throws -> LibraryTrack {
        let reader = try PCMFileReader(url: url)
        let format = reader.format
        guard format.frameCount > 0 else { throw BitPerfectError.decodeFailed(-1) }

        let buffer = UnsafeMutablePointer<Int32>.allocate(capacity: probeFrames * 2)
        defer { buffer.deallocate() }
        let probe = min(Int64(probeFrames), format.frameCount)
        guard try read(reader, into: buffer, frames: Int(probe)) == probe else {
            throw BitPerfectError.decodeFailed(-2)
        }
        try reader.seek(toFrame: format.frameCount - probe)
        guard try read(reader, into: buffer, frames: Int(probe)) == probe else {
            throw BitPerfectError.decodeFailed(-3)
        }

        // 歌手、碟號與搜尋字串由 updating 填入，和更新舊索引走同一段程式
        let tags = TrackMetadata.tags(for: url)
        return LibraryTrack(
            path: url.path,
            title: tags.title,
            artist: "",
            album: tags.album,
            trackNumber: tags.trackNumber,
            discNumber: 0,
            sampleRate: format.sampleRate,
            bitsPerSample: format.bitsPerSample,
            frameCount: format.frameCount,
            titleKey: SearchText.normalize(tags.title),
            artistKey: "",
            searchKey: ""
        ).updating(with: tags)
    }

    private static func read(_ reader: PCMFileReader, into buffer: UnsafeMutablePointer<Int32>, frames: Int) throws -> Int {
        var total = 0
        while total < frames {
            let count = try reader.read(into: buffer + total * 2, frames: frames - total)
            if count == 0 { break }
            total += count
        }
        return total
    }
}

// MARK: - Library

final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()

    /// 目前 DAC 可播放的曲目，也是搜尋的唯一來源
    @Published private(set) var tracks = [LibraryTrack]()
    /// 檔案修改時間，用來排列「最近加入」
    @Published private(set) var addedAt = [String: Double]()
    @Published private(set) var hiddenCount = 0
    @Published private(set) var isScanning = false
    @Published private(set) var folders: [String]

    private let cacheURL: URL
    private let stateLock = NSLock()
    private var entries = [String: LibraryCacheEntry]()
    private var capabilities: DeviceCapabilities?
    private var lastScan: Date?
    private var needsRescan = false

    private static let refreshInterval: TimeInterval = 600

    init(folders: [String]? = nil, cacheURL: URL? = nil) {
        self.folders = folders ?? AppSettings.shared.libraryFolders
        self.cacheURL = cacheURL ?? AppPaths.support.appendingPathComponent("library-v1.json")
        if cacheURL == nil { adoptLosslessSwitcherCache() }
        loadCache()
    }

    func setFolders(_ folders: [String]) {
        self.folders = folders
        AppSettings.shared.libraryFolders = folders
        rescan()
    }

    func isReachable(_ folder: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
    }

    func trackCount(in folder: String) -> Int {
        let prefix = Self.pathPrefix(of: folder)
        return tracks.filter { $0.path.hasPrefix(prefix) }.count
    }

    /// 掃描得到的路徑已解開捷徑，比對前資料夾也要換成同樣的寫法
    static func pathPrefix(of folder: String) -> String {
        let resolved = realpath(folder, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? folder
        return resolved.hasSuffix("/") ? resolved : resolved + "/"
    }

    /// 裝置改變時可播放的範圍也不同，不需要重新掃描
    func updateCapabilities(_ capabilities: DeviceCapabilities?) {
        stateLock.lock()
        let changed = self.capabilities != capabilities
        self.capabilities = capabilities
        stateLock.unlock()
        if changed { publish() }
    }

    /// 改名時修改時間不變，索引裡的資料都還有效，不必重新檢查音訊
    func applyMoves(_ moves: [FileMove]) {
        stateLock.lock()
        for move in moves {
            if let entry = entries.removeValue(forKey: move.from) { entries[move.to] = entry.moved(to: move.to) }
        }
        stateLock.unlock()
        saveCache()
        publish()
    }

    /// 寫入標籤時保留修改時間，新標籤又可能剛好放進補白、大小不變，掃描自己看不出來
    func markOutdated(_ paths: [String]) {
        stateLock.lock()
        for path in paths { entries[path] = entries[path]?.outdated }
        stateLock.unlock()
    }

    func refreshIfStale() {
        if let lastScan, Date().timeIntervalSince(lastScan) < Self.refreshInterval { return }
        rescan()
    }

    func rescan(completion: (() -> Void)? = nil) {
        // 掃描中改了資料夾時，這一輪還是舊的清單，結束後要再掃一次
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        lastScan = Date()
        let folders = self.folders
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.scan(folders: folders)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                self.publish()
                completion?()
                if self.needsRescan {
                    self.needsRescan = false
                    self.rescan()
                }
            }
        }
    }

    /// 同步掃描，回傳時索引已更新
    func scan(folders: [String]) {
        // 外接硬碟未接上或尚未授權時保留該資料夾的索引，不要把音樂清掉；其他資料夾照常掃描
        let reachable = folders.filter(isReachable)
        let unreachable = folders.filter { !reachable.contains($0) }.map(Self.pathPrefix)

        var files = [(url: URL, size: Int64, modified: Double)]()
        var rejectedByType = [String]()
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for folder in reachable {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                              includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                // 收件匣裡是還沒整理好的歌，歸檔後才算進資料庫
                if walker.level == 1, url.lastPathComponent == InboxModel.folderName {
                    walker.skipDescendants()
                    continue
                }
                // 同時加入資料夾與它的子資料夾時，同一個檔案只算一次
                guard seen.insert(url.path).inserted else { continue }
                let fileExtension = url.pathExtension.lowercased()
                if LibraryInspector.rejectedExtensions.contains(fileExtension) {
                    rejectedByType.append(url.path)
                    continue
                }
                guard LibraryInspector.candidateExtensions.contains(fileExtension),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }

        stateLock.lock()
        let previous = entries
        stateLock.unlock()

        var updated = previous.filter { path, _ in unreachable.contains { path.hasPrefix($0) } }
        var pending = [(url: URL, size: Int64, modified: Double)]()
        var outdatedTags = [LibraryCacheEntry]()
        for file in files {
            if let cached = previous[file.url.path], cached.size == file.size, cached.modified == file.modified {
                if let track = cached.track, track.tagVersion != TrackMetadata.version {
                    outdatedTags.append(cached)
                }
                else {
                    updated[file.url.path] = cached
                }
            }
            else {
                pending.append(file)
            }
        }

        let collector = NSLock()
        DispatchQueue.concurrentPerform(iterations: pending.count) { index in
            let file = pending[index]
            let entry: LibraryCacheEntry
            do {
                let track = try LibraryInspector.inspect(url: file.url)
                entry = LibraryCacheEntry(path: file.url.path, size: file.size, modified: file.modified, track: track, rejection: nil)
            }
            catch {
                entry = LibraryCacheEntry(path: file.url.path, size: file.size, modified: file.modified, track: nil,
                                          rejection: error.localizedDescription)
            }
            collector.lock()
            updated[file.url.path] = entry
            collector.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: outdatedTags.count) { index in
            let cached = outdatedTags[index]
            guard let track = cached.track else { return }
            let refreshed = LibraryCacheEntry(path: cached.path, size: cached.size, modified: cached.modified,
                                              track: track.updating(with: TrackMetadata.tags(for: track.url)), rejection: nil)
            collector.lock()
            updated[cached.path] = refreshed
            collector.unlock()
        }

        for path in rejectedByType {
            updated[path] = LibraryCacheEntry(path: path, size: 0, modified: 0, track: nil, rejection: String(localized: "不是可直通的無損 PCM 格式"))
        }

        stateLock.lock()
        entries = updated
        stateLock.unlock()
        saveCache()
    }

    /// 全部條件都要命中；歌名比歌手優先，歌手比專輯與檔名優先
    func search(_ query: String, limit: Int = 60) -> [LibraryTrack] {
        let tokens = SearchText.tokens(of: query)
        guard !tokens.isEmpty else { return [] }

        var matches = [(track: LibraryTrack, rank: Int)]()
        for track in tracks where tokens.allSatisfy({ track.searchKey.contains($0) }) {
            var rank = 3
            if tokens.allSatisfy({ track.titleKey.contains($0) }) {
                rank = track.titleKey.hasPrefix(tokens[0]) ? 0 : 1
            }
            else if tokens.allSatisfy({ track.artistKey.contains($0) }) {
                rank = 2
            }
            matches.append((track, rank))
        }

        matches.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.track.album != rhs.track.album { return lhs.track.album < rhs.track.album }
            return Self.albumOrder(lhs.track, rhs.track)
        }
        return matches.prefix(limit).map(\.track)
    }

    /// 同資料夾的可播放曲目，依碟號與音軌排序，作為播放佇列
    func albumTracks(containing track: LibraryTrack) -> [LibraryTrack] {
        let album = tracks.filter { $0.folder == track.folder }.sorted(by: Self.albumOrder)
        return album.isEmpty ? [track] : album
    }

    /// 重新比對所有快取項目，能播放的才公開
    private func publish() {
        stateLock.lock()
        let snapshot = entries
        let capabilities = self.capabilities
        stateLock.unlock()

        var playable = [LibraryTrack]()
        var added = [String: Double]()
        var hidden = 0
        for entry in snapshot.values {
            if let track = entry.track,
               capabilities?.canPlay(sampleRate: track.sampleRate, bitsPerSample: track.bitsPerSample) ?? true {
                playable.append(track)
                added[track.path] = entry.modified
            }
            else {
                hidden += 1
            }
        }
        playable.sort(by: Self.albumOrder)

        if Thread.isMainThread {
            apply(playable, added: added, hidden: hidden)
        }
        else {
            DispatchQueue.main.async { [weak self] in self?.apply(playable, added: added, hidden: hidden) }
        }
    }

    private func apply(_ playable: [LibraryTrack], added: [String: Double], hidden: Int) {
        tracks = playable
        addedAt = added
        hiddenCount = hidden
    }

    private static func albumOrder(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    /// 第一次啟動時沿用 LosslessSwitcher 的索引，不必重新檢查幾千個檔案；只讀取，不改動它的檔案
    private func adoptLosslessSwitcherCache() {
        let fileManager = FileManager.default
        let source = AppPaths.losslessSwitcherLibraryCache
        guard !fileManager.fileExists(atPath: cacheURL.path), fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.copyItem(at: source, to: cacheURL)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([LibraryCacheEntry].self, from: data) else { return }
        entries = Dictionary(cached.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
        publish()
    }

    private func saveCache() {
        stateLock.lock()
        let snapshot = Array(entries.values)
        stateLock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    #if DEBUG
    var rejections: [(path: String, reason: String)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return entries.values.compactMap { entry in entry.rejection.map { (entry.path, $0) } }
    }

    func publishNow() {
        publish()
    }
    #endif
}
