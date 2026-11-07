//
//  MusicPlaylistModels.swift
//  LosslessCompanion
//
//  Apple Music 播放列表與資料庫的本機副本。順序以 Music 回傳的順序為準。
//

import Foundation

struct MusicPlaylist: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let isSmart: Bool
    let isSubscription: Bool
    let entries: [MusicPlaylistEntry]

    var totalDuration: TimeInterval { entries.reduce(0) { $0 + $1.duration } }
}

struct MusicPlaylistEntry: Codable, Hashable, Identifiable {
    /// 同一首歌可以在歌單裡出現多次，所以 id 要包含位置
    let position: Int
    let trackID: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let duration: TimeInterval
    let trackNumber: Int
    let discNumber: Int
    let year: Int
    let cloudStatus: String
    var genre: String? = nil
    var composer: String? = nil
    var isFavorite: Bool? = nil
    /// 加入資料庫的時間，1970 年起算的秒數
    var dateAdded: Double? = nil

    var id: String { "\(position)-\(trackID)" }

    /// Apple Music 下架的歌曲還留在歌單裡，但已經無法串流
    var isStreamable: Bool { cloudStatus != "no longer available" }
}

struct MusicSnapshot {
    var playlists = [MusicPlaylist]()
    /// 整個 Music 資料庫，用來判斷本地檔案有沒有對應的歌曲，不顯示在側欄
    var library = [MusicPlaylistEntry]()
}

/// Music 資料庫裡的一張專輯。內容包成歌單，播放、封面與來源選擇都和歌單走同一條路，
/// 所有專輯共用同一組來源與排序設定
struct MusicAlbum: Identifiable, Hashable {
    let id: String
    let artist: String
    let addedAt: Double
    let playlist: MusicPlaylist

    var title: String { playlist.name }
}

enum MusicRecents {
    static let albumLimit = 120
    private static let unknownArtist = String(localized: "未知歌手")

    /// 專輯依最後加入的歌曲排序，和 Music 的「最近加入」相同：同一張專輯後來又加歌會排到前面。
    /// 沒有專輯名稱的歌曲各自成一項
    static func albums(from library: [MusicPlaylistEntry], limit: Int = albumLimit) -> [MusicAlbum] {
        Array(allAlbums(from: library).prefix(limit))
    }

    static func allAlbums(from library: [MusicPlaylistEntry]) -> [MusicAlbum] {
        var groups = [String: [MusicPlaylistEntry]]()
        for entry in library {
            groups[entry.album.isEmpty ? entry.trackID : entry.album + "\n" + owner(of: entry), default: []].append(entry)
        }

        return groups.map { key, entries in album(key: key, entries: entries) }
            .sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : $0.id < $1.id }
    }

    /// 每首歌所在的專輯，用來從歌曲跳到專輯頁
    static func albumsByTrack(_ albums: [MusicAlbum]) -> [String: MusicAlbum] {
        var result = [String: MusicAlbum]()
        for album in albums {
            for entry in album.playlist.entries where result[entry.trackID] == nil { result[entry.trackID] = album }
        }
        return result
    }

    private static func album(key: String, entries: [MusicPlaylistEntry]) -> MusicAlbum {
        let ordered = entries.sorted { lhs, rhs in
            (lhs.discNumber, lhs.trackNumber, lhs.position) < (rhs.discNumber, rhs.trackNumber, rhs.position)
        }
        let first = ordered[0]
        let artist = owner(of: first)
        return MusicAlbum(id: key, artist: artist.isEmpty ? unknownArtist : artist,
                          addedAt: entries.compactMap(\.dateAdded).max() ?? 0,
                          playlist: MusicPlaylist(id: MusicScripts.libraryPlaylistID, name: first.album.isEmpty ? first.title : first.album,
                                                  isSmart: false, isSubscription: false, entries: ordered))
    }

    private static func owner(of entry: MusicPlaylistEntry) -> String {
        entry.albumArtist.isEmpty ? entry.artist : entry.albumArtist
    }
}

/// 把腳本回傳的欄位切回播放列表。用控制字元分隔，歌名裡的任何標點都不會影響解析
enum MusicPlaylistParser {
    static let unitSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"
    static let groupSeparator = "\u{1D}"

    static let libraryKind = "library"
    static let subscriptionKind = "subscription"

    private static let headerFields = 5
    private static let trackColumns = 13
    private static let libraryColumns = trackColumns + 1

    static func parse(_ text: String, now: Date = Date()) -> MusicSnapshot {
        var snapshot = MusicSnapshot()
        for group in text.components(separatedBy: groupSeparator) {
            guard let parsed = parseGroup(group, now: now) else { continue }
            if parsed.kind == libraryKind {
                snapshot.library = parsed.playlist.entries
            }
            else {
                snapshot.playlists.append(parsed.playlist)
            }
        }
        return attachDates(snapshot)
    }

    /// 欄位數不一致代表這張歌單資料不完整，寧可略過也不要讓欄位錯位
    private static func parseGroup(_ text: String, now: Date) -> (playlist: MusicPlaylist, kind: String)? {
        let records = text.components(separatedBy: recordSeparator)
        guard let header = records.first else { return nil }
        let fields = header.components(separatedBy: unitSeparator)
        guard fields.count == headerFields, let count = Int(fields[4]), !fields[0].isEmpty else { return nil }
        let kind = fields[3]

        var entries = [MusicPlaylistEntry]()
        if count > 0 {
            let columns = records.dropFirst().map { $0.components(separatedBy: unitSeparator) }
            let expected = kind == libraryKind ? libraryColumns : trackColumns
            guard columns.count == expected, columns.allSatisfy({ $0.count == count }) else { return nil }
            entries.reserveCapacity(count)
            for row in 0..<count {
                entries.append(MusicPlaylistEntry(position: row,
                                                  trackID: columns[0][row],
                                                  title: field(columns[1][row]),
                                                  artist: field(columns[2][row]),
                                                  albumArtist: field(columns[3][row]),
                                                  album: field(columns[4][row]),
                                                  duration: number(columns[5][row]),
                                                  trackNumber: Int(number(columns[6][row])),
                                                  discNumber: Int(number(columns[7][row])),
                                                  year: Int(number(columns[8][row])),
                                                  cloudStatus: field(columns[9][row]),
                                                  genre: field(columns[10][row]),
                                                  composer: field(columns[11][row]),
                                                  isFavorite: columns[12][row] == "true",
                                                  dateAdded: kind == libraryKind ? now.timeIntervalSince1970 + number(columns[13][row]) : nil))
            }
        }
        let playlist = MusicPlaylist(id: fields[0], name: fields[1], isSmart: fields[2] == "true",
                                     isSubscription: kind == subscriptionKind, entries: entries)
        return (playlist, kind)
    }

    /// 只有資料庫讀取日期，歌單裡同一首歌沿用，這樣歌單也能依加入日期排序
    private static func attachDates(_ snapshot: MusicSnapshot) -> MusicSnapshot {
        let dates = Dictionary(snapshot.library.compactMap { entry in entry.dateAdded.map { (entry.trackID, $0) } },
                               uniquingKeysWith: { first, _ in first })
        guard !dates.isEmpty else { return snapshot }
        var result = snapshot
        result.playlists = snapshot.playlists.map { playlist in
            let entries = playlist.entries.map { entry -> MusicPlaylistEntry in
                var copy = entry
                copy.dateAdded = dates[entry.trackID]
                return copy
            }
            return MusicPlaylist(id: playlist.id, name: playlist.name, isSmart: playlist.isSmart,
                                 isSubscription: playlist.isSubscription, entries: entries)
        }
        return result
    }

    private static func field(_ value: String) -> String {
        value == "missing value" ? "" : value
    }

    /// 部分語系的小數點是逗號
    private static func number(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
