//
//  LibraryBrowser.swift
//  LosslessCompanion
//
//  把本地音檔整理成 Apple Music 的分類：專輯、歌手、類型、作曲者、合輯。
//  有配對到 Music 的歌曲以 Music 的資料為準，其餘用檔案標籤，類型名稱統一成 Music 使用的寫法。
//

import Foundation

struct AlbumGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [LibraryTrack]
    let addedAt: Double
    var genre = GenreName.unclassified
    var year = 0
    var isCompilation = false

    var representative: LibraryTrack { tracks[0] }
    var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    /// 由小到大，混合專輯會有好幾個
    var sampleRates: [Double] { Set(tracks.map(\.sampleRate)).sorted() }

    /// 同一張專輯裡規格最高的曲目，用來顯示專輯的規格標籤
    var bestFormat: (sampleRate: Double, bits: Int) {
        let best = tracks.max { ($0.sampleRate, $0.bitsPerSample) < ($1.sampleRate, $1.bitsPerSample) } ?? representative
        return (best.sampleRate, best.bitsPerSample)
    }
}

/// 取樣率相同的專輯；混合的專輯依組合自成一類，例如 48/96 kHz
struct AlbumRateGroup: Identifiable, Hashable {
    let rates: [Double]
    let albums: [AlbumGroup]

    var id: [Double] { rates }
    var title: String { Format.sampleRates(rates) }
}

struct ArtistGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [AlbumGroup]
    /// 別人專輯裡有這位歌手的歌，例如客串與合輯
    var guestTracks = [LibraryTrack]()

    var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    /// 這位歌手在硬碟上的所有檔案
    var allTracks: [LibraryTrack] { albums.flatMap(\.tracks) + guestTracks }
}

/// 一首歌的歌手欄位可能列了好幾個人
enum ArtistCredit {
    private static let separator = try! NSRegularExpression(
        pattern: #"\s*(?:[,，、&＆/／;；×]|\b(?:feat\.?|ft\.?|featuring|with)(?=\s)|\sx\s)\s*"#, options: .caseInsensitive)

    /// 完整的欄位也算一個名字，「Simon & Garfunkel」這種團名才找得到
    static func names(in artist: String) -> [String] {
        let range = NSRange(artist.startIndex..., in: artist)
        let marked = separator.stringByReplacingMatches(in: artist, range: range, withTemplate: "\u{1F}")
        let parts = marked.components(separatedBy: "\u{1F}").filter { !$0.isEmpty && $0 != artist }
        return [artist] + parts
    }
}

/// 類型與作曲者共用的分組
struct CategoryGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [AlbumGroup]

    var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
}

/// 本地標籤寫法很雜，例如 JPOP、J-POP/General、Soundtracks，統一成 Music 的類型名稱才分得起來
enum GenreName {
    static let unclassified = String(localized: "未分類")

    private static let aliases: [String: String] = [
        "j-pop": "J-Pop", "jpop": "J-Pop", "j pop": "J-Pop", "j-pop/general": "J-Pop", "ポップス": "J-Pop", "日本流行樂": "J-Pop",
        "pop": "Pop", "流行": "Pop", "流行音樂": "Pop", "pop/rock": "Pop/Rock",
        "mandopop": "Mandopop", "c-pop": "Mandopop", "cpop": "Mandopop", "華語流行": "Mandopop", "华语流行": "Mandopop", "中文流行": "Mandopop",
        "alternative": "Alternative", "alternative & indie": "Alternative", "alternative/indie rock": "Alternative", "alt": "Alternative",
        "alternative rock": "Alternative", "alternativ und indie": "Alternative",
        "indie rock": "Indie Rock", "indie": "Indie Rock", "indie pop": "Indie Pop",
        "rock": "Rock", "ロック": "Rock", "搖滾": "Rock", "摇滚": "Rock",
        "metal": "Metal", "メタル": "Metal", "heavy metal": "Metal",
        "hip-hop/rap": "Hip-Hop/Rap", "rap/hip hop": "Hip-Hop/Rap", "hip hop": "Hip-Hop/Rap", "hip-hop": "Hip-Hop/Rap", "rap": "Hip-Hop/Rap",
        "rap & hip-hop": "Hip-Hop/Rap",
        "r&b/soul": "R&B/Soul", "r&b": "R&B/Soul", "rnb": "R&B/Soul", "soul": "R&B/Soul",
        "classical": "Classical", "classic": "Classical", "classical, instrumental": "Classical", "klassik": "Classical", "classique": "Classical",
        "violin solos": "Classical", "opera": "Classical", "古典": "Classical", "クラシック": "Classical",
        "soundtrack": "Soundtrack", "soundtracks": "Soundtrack", "film soundtracks": "Soundtrack", "cinema music": "Soundtrack",
        "game soundtrack": "Soundtrack", "ost": "Soundtrack", "原聲帶": "Soundtrack", "サウンドトラック": "Soundtrack",
        "anime": "Anime", "アニメ": "Anime", "動漫": "Anime",
        "electronic": "Electronic", "electronica": "Electronic", "edm": "Electronic", "電子": "Electronic",
        "dance": "Dance", "jazz": "Jazz", "爵士": "Jazz", "folk": "Folk", "民謠": "Folk",
        "singer/songwriter": "Singer/Songwriter"
    ]

    /// 這些標籤沒有分類意義，當成沒有標籤
    private static let meaningless: Set<String> = [
        "", "miscellaneous", "other", "unknown", "general", "asia", "international/far east & asia", "world", "default", "none"
    ]

    /// 無法辨識的標籤保留原文，空值回傳 nil。一個欄位放多個類型時取第一個，
    /// Classical/Symphonies 這種子分類歸到主類型
    static func canonical(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ";", omittingEmptySubsequences: true).first.map(String.init) ?? raw
        var trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("/general") { trimmed = String(trimmed.dropLast("/general".count)) }
        let key = trimmed.lowercased()
        guard !meaningless.contains(key) else { return nil }
        if key.hasPrefix("classical/") { return "Classical" }
        return aliases[key] ?? trimmed
    }
}

/// 依規格篩選本地音樂。同一類可複選，符合其中一項就算；不同類要同時符合。
/// 專輯只要有一首符合就算，跨類時也要是同一首符合
struct FormatFilter: Hashable {
    enum Tier: CaseIterable {
        case hiRes
        case standard

        var title: String {
            switch self {
            case .hiRes: return "Hi-Res"
            case .standard: return String(localized: "CD 規格以下")
            }
        }
    }

    static let all = FormatFilter()

    var tiers = Set<Tier>()
    var sampleRates = Set<Double>()
    var bitDepths = Set<Int>()
    var fileTypes = Set<String>()

    /// 目前選的每一項，順序和選單相同
    var titles: [String] {
        Tier.allCases.filter(tiers.contains).map(\.title)
            + sampleRates.sorted().map { Format.sampleRate($0) }
            + bitDepths.sorted().map(Self.title(bits:))
            + fileTypes.sorted()
    }

    var title: String {
        titles.isEmpty ? String(localized: "全部") : titles.joined(separator: String(localized: "、"))
    }

    func matches(_ track: LibraryTrack) -> Bool {
        (tiers.isEmpty || tiers.contains(Format.isHiRes(rate: track.sampleRate, bits: track.bitsPerSample) ? .hiRes : .standard))
            && (sampleRates.isEmpty || sampleRates.contains(track.sampleRate))
            && (bitDepths.isEmpty || bitDepths.contains(track.bitsPerSample))
            && (fileTypes.isEmpty || fileTypes.contains(Self.fileType(of: track)))
    }

    func matches(_ album: AlbumGroup) -> Bool {
        album.tracks.contains(where: matches)
    }

    static func title(bits: Int) -> String {
        "\(bits)-bit"
    }

    static func fileType(of track: LibraryTrack) -> String {
        track.url.pathExtension.uppercased()
    }
}

/// 介面需要的所有本地分類，在背景算好一次發布
struct LibraryIndex {
    var albums = [AlbumGroup]()
    /// 本地檔案所在的專輯，Apple Music 的歌曲用來跳到本地專輯
    var albumsByPath = [String: AlbumGroup]()
    /// 開著的頁面用 id 取回最新的專輯；併入別張專輯的舊 id 也查得到
    var albumsByID = [String: AlbumGroup]()
    var artists = [ArtistGroup]()
    var artistsByName = [String: ArtistGroup]()
    var genres = [CategoryGroup]()
    var composers = [CategoryGroup]()
    var compilations = [AlbumGroup]()
    var recent = [AlbumGroup]()
    /// Music 資料庫最近加入的專輯，不限於有本地檔案的
    var recentMusic = [MusicAlbum]()
    /// Music 資料庫每首歌所在的專輯，以歌曲 ID 查
    var musicAlbumsByTrack = [String: MusicAlbum]()
    /// 還等著校閱的曲目；手動連結與標記為僅本地的不在裡面
    var unmatchedTracks = [LibraryTrack]()
    var unmatchedAlbums = [AlbumGroup]()
    var unmatchedPaths = Set<String>()
    var linkedTracks = [LibraryTrack]()
    var localOnlyTracks = [LibraryTrack]()

    private static let recentLimit = 120

    /// apple：本地檔案路徑對應到的 Music 歌曲，沒有配對到的就不在裡面
    static func build(tracks: [LibraryTrack], addedAt: [String: Double], apple: [String: MusicPlaylistEntry],
                      decisions: MatchDecisions = MatchDecisions(), merges: AlbumMerges = AlbumMerges()) -> LibraryIndex {
        var index = LibraryIndex()
        let lookup = merges.lookup
        index.albums = LibraryBrowser.albums(from: tracks, addedAt: addedAt, apple: apple, merges: lookup)
        for album in index.albums {
            for track in album.tracks { index.albumsByPath[track.path] = album }
            index.albumsByID[album.id] = album
            lookup.merge(for: album.id)?.folders.forEach { index.albumsByID[$0] = album }
        }
        index.artists = LibraryBrowser.artists(from: index.albums)
        index.artistsByName = Dictionary(index.artists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        index.genres = LibraryBrowser.genres(from: index.albums)
        index.composers = LibraryBrowser.composers(from: index.albums, apple: apple)
        index.compilations = index.albums.filter(\.isCompilation)
        index.recent = Array(index.albums.sorted { $0.addedAt > $1.addedAt }.prefix(recentLimit))
        index.unmatchedTracks = tracks.filter { apple[$0.path] == nil && !decisions.localOnly.contains($0.path) }
        index.unmatchedAlbums = LibraryBrowser.albums(from: index.unmatchedTracks, addedAt: addedAt, apple: apple, merges: lookup)
        index.unmatchedPaths = Set(index.unmatchedTracks.map(\.path))
        index.linkedTracks = tracks.filter { decisions.links[$0.path] != nil }
        index.localOnlyTracks = tracks.filter { decisions.localOnly.contains($0.path) }
        return index
    }
}

enum LibraryBrowser {
    private static let discFolderPattern = try! NSRegularExpression(pattern: #"^(disc|disk|cd)\s*\d+$"#, options: .caseInsensitive)
    private static let composerSeparators = CharacterSet(charactersIn: ";；/／、")
    private static let variousArtists: Set<String> = ["various artists", "various", "va", "v.a.", "群星", "合輯", "オムニバス"]
    /// 沒有專輯歌手標籤時，歌手這麼多就當成合輯
    private static let compilationArtistCount = 4
    private static let compilationDisplayName = String(localized: "群星")

    static func albums(from tracks: [LibraryTrack], addedAt: [String: Double], apple: [String: MusicPlaylistEntry] = [:],
                       merges: AlbumMergeLookup = AlbumMergeLookup()) -> [AlbumGroup] {
        var groups = [String: [(track: LibraryTrack, folder: String)]]()
        for track in tracks {
            let folder = albumFolder(of: track)
            groups[merges.group(of: folder), default: []].append((track, folder))
        }

        return groups.map { group, members in
            let merge = merges.merge(for: group)
            let ordered = ordered(members, merge: merge)
            let matched = ordered.compactMap { apple[$0.path] }
            let isCompilation = isCompilation(ordered, matched: matched)
            let artist = isCompilation ? compilationDisplayName : albumArtist(of: ordered, matched: matched)
            return AlbumGroup(id: group,
                              title: merge?.title ?? ordered[0].album,
                              artist: artist,
                              tracks: ordered,
                              addedAt: ordered.compactMap { addedAt[$0.path] }.max() ?? 0,
                              genre: genre(of: ordered, matched: matched),
                              year: year(of: ordered, matched: matched),
                              isCompilation: isCompilation)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 由低到高；混合的組合排在它最低的取樣率後面，傳入的專輯順序不變
    static func rateGroups(from albums: [AlbumGroup]) -> [AlbumRateGroup] {
        Dictionary(grouping: albums, by: \.sampleRates)
            .map { AlbumRateGroup(rates: $0.key, albums: $0.value) }
            .sorted { $0.rates.lexicographicallyPrecedes($1.rates) }
    }

    static func artists(from albums: [AlbumGroup]) -> [ArtistGroup] {
        var groups = [String: [AlbumGroup]]()
        for album in albums where !album.isCompilation {
            groups[album.artist, default: []].append(album)
        }

        var guests = [String: [LibraryTrack]]()
        for album in albums {
            for track in album.tracks {
                for name in ArtistCredit.names(in: track.artist) where name != album.artist && groups[name] != nil {
                    guests[name, default: []].append(track)
                }
            }
        }
        return groups.map { ArtistGroup(id: $0.key, name: $0.key, albums: $0.value, guestTracks: guests[$0.key] ?? []) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func genres(from albums: [AlbumGroup]) -> [CategoryGroup] {
        categories(Dictionary(grouping: albums, by: \.genre).mapValues { $0 }, idPrefix: "genre")
    }

    static func composers(from albums: [AlbumGroup], apple: [String: MusicPlaylistEntry]) -> [CategoryGroup] {
        var groups = [String: [AlbumGroup]]()
        for album in albums {
            var names = Set<String>()
            for track in album.tracks {
                let raw = track.composer ?? apple[track.path]?.composer ?? ""
                raw.components(separatedBy: composerSeparators)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .forEach { names.insert($0) }
            }
            names.forEach { groups[$0, default: []].append(album) }
        }
        return categories(groups, idPrefix: "composer")
    }

    private static func categories(_ groups: [String: [AlbumGroup]], idPrefix: String) -> [CategoryGroup] {
        groups.map { name, albums in CategoryGroup(id: "\(idPrefix):\(name)", name: name, albums: albums) }
            .sorted { lhs, rhs in
                // 未分類放最後，不要排在類型中間
                if (lhs.name == GenreName.unclassified) != (rhs.name == GenreName.unclassified) {
                    return rhs.name == GenreName.unclassified
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func playOrder(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    /// 專輯跨資料夾時先依資料夾分開，碟號又相同的話，兩邊的第 1 軌才不會排在一起
    private static func ordered(_ members: [(track: LibraryTrack, folder: String)], merge: AlbumMerge?) -> [LibraryTrack] {
        let folders = Set(members.map { $0.track.folder })
        guard folders.count > 1 else { return members.map(\.track).sorted(by: playOrder) }
        let names = folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let ranks = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        let decorated = members.map { (track: $0.track, merged: merge?.folders.firstIndex(of: $0.folder) ?? 0, folder: ranks[$0.track.folder] ?? 0) }
        return decorated.sorted { lhs, rhs in
            if lhs.merged != rhs.merged { return lhs.merged < rhs.merged }
            if lhs.track.discNumber != rhs.track.discNumber { return lhs.track.discNumber < rhs.track.discNumber }
            if lhs.folder != rhs.folder { return lhs.folder < rhs.folder }
            return playOrder(lhs.track, rhs.track)
        }.map(\.track)
    }

    /// 分碟放在子資料夾時仍算同一張專輯
    static func albumFolder(of track: LibraryTrack) -> String {
        let folder = URL(fileURLWithPath: track.folder)
        let name = folder.lastPathComponent
        let isDisc = discFolderPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        return isDisc ? folder.deletingLastPathComponent().path : folder.path
    }

    /// 同一張專輯只要有一首配對到，整張都沿用 Music 的類型
    private static func genre(of tracks: [LibraryTrack], matched: [MusicPlaylistEntry]) -> String {
        mostCommon(matched.compactMap { GenreName.canonical($0.genre) })
            ?? mostCommon(tracks.compactMap { GenreName.canonical($0.genre) })
            ?? GenreName.unclassified
    }

    private static func year(of tracks: [LibraryTrack], matched: [MusicPlaylistEntry]) -> Int {
        tracks.compactMap(\.year).max() ?? matched.map(\.year).max() ?? 0
    }

    private static func albumArtist(of tracks: [LibraryTrack], matched: [MusicPlaylistEntry]) -> String {
        mostCommon(tracks.compactMap(\.albumArtist))
            ?? mostCommon(matched.map(\.albumArtist).filter { !$0.isEmpty })
            ?? mostCommon(tracks.map(\.artist).filter { !$0.isEmpty })
            ?? String(localized: "未知歌手")
    }

    private static func isCompilation(_ tracks: [LibraryTrack], matched: [MusicPlaylistEntry]) -> Bool {
        if tracks.contains(where: { $0.isCompilation == true }) { return true }
        let named = tracks.compactMap(\.albumArtist) + matched.map(\.albumArtist).filter { !$0.isEmpty }
        if let name = mostCommon(named) { return variousArtists.contains(name.lowercased()) }
        return Set(tracks.map(\.artist)).count >= compilationArtistCount
    }

    private static func mostCommon(_ values: [String]) -> String? {
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
