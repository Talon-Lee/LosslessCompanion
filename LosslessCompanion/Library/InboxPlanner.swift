//
//  InboxPlanner.swift
//  LosslessCompanion
//
//  收件匣的歌要放到哪裡：標籤以 Apple Music 為準，類別依現有的歌手資料夾或類型決定。
//  這裡只做判斷，不碰檔案，方便測試。
//

import Foundation

struct InboxMetadata: Codable, Equatable {
    var title = ""
    var artist = ""
    var albumArtist = ""
    var album = ""
    var genre = ""
    var composer = ""
    var trackNumber = 0
    var discNumber = 0
    var year = 0

    init() {}

    init(tags: TrackTags) {
        title = tags.title
        artist = tags.artist
        albumArtist = tags.albumArtist
        album = tags.album
        genre = tags.genre
        composer = tags.composer
        trackNumber = tags.trackNumber
        discNumber = tags.discNumber
        year = tags.year
    }

    /// Apple Music 有的欄位以它為準，沒有的沿用檔案原本的
    init(entry: MusicPlaylistEntry, fallback: InboxMetadata) {
        self = fallback
        if !entry.title.isEmpty { title = entry.title }
        if !entry.artist.isEmpty { artist = entry.artist }
        if !entry.albumArtist.isEmpty { albumArtist = entry.albumArtist }
        else if !entry.artist.isEmpty, !TrackMatcher.overlaps(TrackMatcher.artistSet(fallback.albumArtist), TrackMatcher.artistSet(entry.artist)) {
            albumArtist = entry.artist
        }
        if !entry.album.isEmpty { album = entry.album }
        if let genre = entry.genre, !genre.isEmpty { self.genre = genre }
        if let composer = entry.composer, !composer.isEmpty { self.composer = composer }
        if entry.trackNumber > 0 { trackNumber = entry.trackNumber }
        if entry.discNumber > 0 { discNumber = entry.discNumber }
        if entry.year > 0 { year = entry.year }
    }

    var folderArtist: String { albumArtist.isEmpty ? artist : albumArtist }

    /// 寫進檔案的完整標籤，空的欄位不寫
    var tagUpdate: TagUpdate {
        var update = TagUpdate()
        if !title.isEmpty { update.title = title }
        if !artist.isEmpty { update.artist = artist }
        if !albumArtist.isEmpty { update.albumArtist = albumArtist }
        if !album.isEmpty { update.album = album }
        if trackNumber > 0 { update.trackNumber = trackNumber }
        if discNumber > 0 { update.discNumber = discNumber }
        if !genre.isEmpty { update.genre = genre }
        if !composer.isEmpty { update.composer = composer }
        if year > 0 { update.year = year }
        return update
    }
}

enum InboxSource: String, Codable {
    case musicLibrary
    case appleCatalog
    case fileTags

    var label: String {
        switch self {
        case .musicLibrary: return String(localized: "Music 資料庫")
        case .appleCatalog: return String(localized: "Apple Music 目錄")
        case .fileTags: return String(localized: "檔案本身的標籤")
        }
    }
}

enum InboxGroup: String, Codable, CaseIterable {
    case japanese
    case chinese
    case classical
    case western
}

struct InboxPlan: Codable, Equatable {
    var metadata: InboxMetadata
    var source: InboxSource
    /// 根資料夾下的第一層，例如 JPOP；nil 代表判斷不出來
    var category: String?
    var artistFolder: String
    var albumFolder: String
    var fileName: String
    /// Apple Music 目錄的封面，檔案沒有封面時下載
    var artworkURL: String?
    /// 不能自動歸檔的原因；空的代表可以直接處理
    var concerns: [String]

    var isConfident: Bool { concerns.isEmpty && category != nil }

    func destination(root: URL) -> URL? {
        guard let category else { return nil }
        return root.appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(artistFolder, isDirectory: true)
            .appendingPathComponent(albumFolder, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    var relativeDestination: String {
        [category ?? "?", artistFolder, albumFolder, fileName].joined(separator: "/")
    }
}

/// 根資料夾目前的樣子：有哪些類別、每個類別裡有哪些歌手資料夾
struct InboxLayout {
    let root: URL
    let categories: [String]
    /// 類別 → 歌手資料夾名稱
    let artistFolders: [String: [String]]
    /// 從資料庫裡現有的歌得知某位歌手放在哪裡，資料夾名稱和歌手名稱不同時（例如「馬友友」）也找得到
    let knownArtists: [String: (category: String, folder: String)]

    static let ignoredCategories: Set<String> = ["Music", "Automatically Add to Music.localized"]

    static func scan(root: URL, inboxName: String, tracks: [LibraryTrack]) -> InboxLayout {
        let manager = FileManager.default
        func folders(in url: URL) -> [String] {
            let names = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { name in
                var isDirectory: ObjCBool = false
                return !name.hasPrefix(".") && manager.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }.sorted()
        }
        let categories = folders(in: root).filter { $0 != inboxName && !ignoredCategories.contains($0) }
        var artistFolders = [String: [String]]()
        for category in categories { artistFolders[category] = folders(in: root.appendingPathComponent(category)) }

        let prefix = LocalLibrary.pathPrefix(of: root.path)
        var votes = [String: [String: Int]]()
        for track in tracks where track.path.hasPrefix(prefix) {
            let parts = track.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            // 類別／歌手／專輯／檔案；直接放在類別裡的專輯資料夾不算歌手資料夾
            guard parts.count >= 4, categories.contains(parts[0]) else { continue }
            let location = parts[0] + "/" + parts[1]
            for name in TrackMatcher.artistSet(track.albumArtist ?? "").union(TrackMatcher.artistSet(track.artist)) {
                votes[name, default: [:]][location, default: 0] += 1
            }
        }
        var known = [String: (category: String, folder: String)]()
        for (name, locations) in votes {
            guard let best = locations.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { continue }
            let parts = best.key.split(separator: "/", maxSplits: 1).map(String.init)
            known[name] = (parts[0], parts[1])
        }
        return InboxLayout(root: root, categories: categories, artistFolders: artistFolders, knownArtists: known)
    }

    /// 類別資料夾的名稱對應到哪一組，例如 JPOP → 日文、CN & Indie Rock → 華語
    func category(for group: InboxGroup) -> String? {
        categories.first { InboxPlanner.group(ofCategory: $0) == group }
    }

    func albumFolders(category: String, artistFolder: String) -> [String] {
        let url = root.appendingPathComponent(category).appendingPathComponent(artistFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}

enum InboxPlanner {
    static func plan(metadata: InboxMetadata, source: InboxSource, fileExtension: String, layout: InboxLayout,
                     artworkURL: String? = nil, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> InboxPlan {
        var concerns = [String]()
        if source == .fileTags { concerns.append(String(localized: "Apple Music 找不到這首歌，標籤來自檔案本身")) }
        if metadata.title.isEmpty || metadata.folderArtist.isEmpty { concerns.append(String(localized: "缺少歌名或歌手")) }

        var category: String?
        var artistFolder = FileNamer.sanitized(metadata.folderArtist)
        if let existing = existingArtistFolder(for: metadata, in: layout) {
            category = existing.category
            artistFolder = existing.folder
        }
        else if let guess = group(for: metadata) {
            category = layout.category(for: guess.group)
            if !guess.isConfident { concerns.append(String(localized: "類別是用歌名的文字猜的")) }
        }
        if category == nil { concerns.append(String(localized: "無法判斷要放在哪個類別")) }
        if artistFolder.isEmpty { artistFolder = String(localized: "未知歌手") }

        let albumFolder = category.flatMap { existingAlbumFolder(for: metadata, in: layout.albumFolders(category: $0, artistFolder: artistFolder)) }
            ?? albumFolderName(for: metadata)
        var plan = InboxPlan(metadata: metadata, source: source, category: category, artistFolder: artistFolder,
                             albumFolder: albumFolder, fileName: fileName(for: metadata, extension: fileExtension),
                             artworkURL: artworkURL, concerns: concerns)
        if let destination = plan.destination(root: layout.root), exists(destination) {
            plan.concerns.append(String(localized: "目的地已經有同名檔案，可能是重複的歌"))
        }
        return plan
    }

    /// 改了標籤或類別之後重新算資料夾與檔名，原本的疑慮只留下仍然成立的
    static func replan(_ plan: InboxPlan, metadata: InboxMetadata, category: String?, fileExtension: String,
                       layout: InboxLayout) -> InboxPlan {
        var updated = self.plan(metadata: metadata, source: plan.source, fileExtension: fileExtension, layout: layout,
                                artworkURL: plan.artworkURL)
        if let category, category != updated.category {
            updated.category = category
            updated.albumFolder = existingAlbumFolder(for: metadata, in: layout.albumFolders(category: category, artistFolder: updated.artistFolder))
                ?? albumFolderName(for: metadata)
        }
        return updated
    }

    // MARK: Folders

    static func existingArtistFolder(for metadata: InboxMetadata, in layout: InboxLayout) -> (category: String, folder: String)? {
        let primary = TrackMatcher.artistSet(metadata.folderArtist)
        let names = primary.isEmpty ? TrackMatcher.artistSet(metadata.artist) : primary
        for category in layout.categories {
            for folder in layout.artistFolders[category] ?? [] where names.contains(compactName(folder)) {
                return (category, folder)
            }
        }
        for name in names {
            if let known = layout.knownArtists[name] { return known }
        }
        return nil
    }

    static func existingAlbumFolder(for metadata: InboxMetadata, in folders: [String]) -> String? {
        let key = TrackMatcher.albumKey(metadata.album)
        guard !key.isEmpty else { return nil }
        let artist = metadata.folderArtist
        return folders.first { folder in
            var name = folder
            if !artist.isEmpty, name.lowercased().hasPrefix(artist.lowercased() + " - ") { name.removeFirst(artist.count + 3) }
            return TrackMatcher.albumKey(name) == key
        }
    }

    /// 和現有的資料夾同一種寫法：「歌手 - 專輯 (年份)」，Music 型錄的「 - Single」不放進資料夾名稱
    static func albumFolderName(for metadata: InboxMetadata) -> String {
        var album = metadata.album.isEmpty ? metadata.title : metadata.album
        for suffix in [" - Single", " - EP"] where album.hasSuffix(suffix) { album.removeLast(suffix.count) }
        var name = [metadata.folderArtist, album].filter { !$0.isEmpty }.joined(separator: " - ")
        if metadata.year > 0 { name += " (\(metadata.year))" }
        return FileNamer.fileName(stem: name, extension: "")
    }

    static func fileName(for metadata: InboxMetadata, extension fileExtension: String) -> String {
        let number = metadata.trackNumber > 0 ? String(format: "%02d", metadata.trackNumber) : ""
        let position = metadata.discNumber > 1 && !number.isEmpty ? "\(metadata.discNumber)-\(number)" : number
        let stem = [position, metadata.title].filter { !$0.isEmpty }.joined(separator: " - ")
        return FileNamer.fileName(stem: stem.isEmpty ? String(localized: "未命名") : stem, extension: fileExtension.lowercased())
    }

    static func compactName(_ text: String) -> String {
        TitleFingerprint.compact(SearchText.normalize(text))
    }

    // MARK: Categories

    private static let japaneseWords = ["j-pop", "jpop", "j-rock", "anime", "アニメ", "動畫", "动画", "動漫", "动漫", "日本", "japan",
                                        "vocaloid", "演歌", "enka", "歌謡", "歌謠", "kayokyoku"]
    private static let chineseWords = ["mandopop", "cantopop", "c-pop", "cpop", "chinese", "華語", "华语", "中文", "國語", "国语",
                                       "粵語", "粤语", "台語", "台语", "taiwan", "台灣", "香港"]
    private static let classicalWords = ["classical", "古典", "soundtrack", "原聲", "原声", "サウンドトラック", "score", "opera",
                                         "歌劇", "歌剧", "orchestral", "管弦", "クラシック"]

    /// 類型明確時直接用；流行、搖滾這類不分語言的類型，看歌名與歌手用的文字
    static func group(for metadata: InboxMetadata) -> (group: InboxGroup, isConfident: Bool)? {
        let genre = metadata.genre.lowercased()
        if !genre.isEmpty {
            if japaneseWords.contains(where: genre.contains) { return (.japanese, true) }
            if chineseWords.contains(where: genre.contains) { return (.chinese, true) }
            if classicalWords.contains(where: genre.contains) || genre.split(whereSeparator: { !$0.isLetter }).contains("ost") {
                return (.classical, true)
            }
        }
        let text = [metadata.title, metadata.artist, metadata.albumArtist, metadata.album].joined(separator: " ")
        let script = Script(text)
        let hasGenre = !genre.isEmpty
        if script.hasKana { return (.japanese, true) }
        if script.hasHangul { return (.western, false) }
        if script.hasHan { return (.chinese, hasGenre) }
        if script.hasLatin { return (.western, hasGenre) }
        return nil
    }

    static func group(ofCategory name: String) -> InboxGroup? {
        let lowered = name.lowercased()
        let tokens = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if tokens.contains("jpop") || tokens.contains("j") && tokens.contains("pop") || lowered.contains("日") || tokens.contains("anime") {
            return .japanese
        }
        if tokens.contains("cn") || ["華語", "华语", "中文", "國語"].contains(where: lowered.contains) || tokens.contains("mandopop") {
            return .chinese
        }
        if tokens.contains("classical") || tokens.contains("ost") || lowered.contains("古典") { return .classical }
        if lowered.contains("西洋") || tokens.contains("western") || tokens.contains("pop") || lowered.contains("歐美") {
            return .western
        }
        return nil
    }

    private struct Script {
        var hasKana = false
        var hasHan = false
        var hasHangul = false
        var hasLatin = false

        init(_ text: String) {
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: hasKana = true
                case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: hasHan = true
                case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hasHangul = true
                case 0x41...0x5A, 0x61...0x7A: hasLatin = true
                default: break
                }
            }
        }
    }
}
