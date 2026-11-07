//
//  TrackSorting.swift
//  LosslessCompanion
//
//  歌曲排序，選項與 Apple Music 的檢視排序相同。排序只影響這裡的顯示與待播順序，不會改動 Music 裡的歌單。
//

import Foundation

enum TrackSortKey: String, CaseIterable, Identifiable {
    /// 歌單是 Music 回傳的順序，本地清單是專輯順序
    case original
    case title, artist, album, genre, year, duration, dateAdded, plays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return String(localized: "原始順序")
        case .title: return String(localized: "歌名")
        case .artist: return String(localized: "field.artist", defaultValue: "歌手")
        case .album: return String(localized: "field.album", defaultValue: "專輯")
        case .genre: return String(localized: "field.genre", defaultValue: "類型")
        case .year: return String(localized: "年份")
        case .duration: return String(localized: "時長")
        case .dateAdded: return String(localized: "加入日期")
        case .plays: return String(localized: "播放次數")
        }
    }

    static let selectable: [TrackSortKey] = [.title, .artist, .album, .genre, .year, .duration, .dateAdded]
    /// 只有本地檔案有播放次數
    static let localSelectable = selectable + [.plays]

    /// 日期、年份與次數預設從大到小，其餘從小到大
    var defaultAscending: Bool {
        self != .dateAdded && self != .year && self != .plays
    }
}

struct TrackSort: Equatable {
    var key: TrackSortKey
    var ascending: Bool

    static let original = TrackSort(key: .original, ascending: true)

    init(key: TrackSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":").map(String.init)
        guard parts.count == 2, let key = TrackSortKey(rawValue: parts[0]) else { return nil }
        self.init(key: key, ascending: parts[1] == "asc")
    }

    var storage: String { "\(key.rawValue):\(ascending ? "asc" : "desc")" }

    /// 點欄位標題：同一欄反向，換欄從該欄預設方向開始
    func tapped(_ newKey: TrackSortKey) -> TrackSort {
        newKey == key ? TrackSort(key: key, ascending: !ascending)
                      : TrackSort(key: newKey, ascending: newKey.defaultAscending)
    }
}

/// 排序需要的欄位，歌單項目與本地檔案都用這個形狀比較
struct TrackSortFields {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var year: Int
    var duration: TimeInterval
    var dateAdded: Double
    var discNumber: Int
    var trackNumber: Int
    var plays = 0
}

extension MusicPlaylistEntry {
    var sortFields: TrackSortFields {
        TrackSortFields(title: title, artist: albumArtist.isEmpty ? artist : albumArtist, album: album, genre: genre ?? "",
                        year: year, duration: duration, dateAdded: dateAdded ?? 0,
                        discNumber: discNumber, trackNumber: trackNumber)
    }
}

extension LibraryTrack {
    func sortFields(addedAt: Double, plays: Int = 0) -> TrackSortFields {
        TrackSortFields(title: title, artist: albumArtist ?? artist, album: album, genre: genre ?? "",
                        year: year ?? 0, duration: duration, dateAdded: addedAt,
                        discNumber: discNumber, trackNumber: trackNumber, plays: plays)
    }
}

enum TrackSorter {
    /// 相同時依歌手、專輯、碟號、音軌、原本的位置，順序才不會每次重排都不同
    static func sorted<Item>(_ items: [Item], by sort: TrackSort, fields: (Item) -> TrackSortFields) -> [Item] {
        guard sort.key != .original else { return sort.ascending ? items : items.reversed() }
        let decorated = items.enumerated().map { (offset: $0.offset, item: $0.element, fields: fields($0.element)) }
        return decorated.sorted { lhs, rhs in
            let primary = compare(lhs.fields, rhs.fields, by: sort.key, ascending: sort.ascending)
            if primary != .orderedSame { return primary == .orderedAscending }
            let secondary = tieBreak(lhs.fields, rhs.fields, primary: sort.key)
            if secondary != .orderedSame { return secondary == .orderedAscending }
            return lhs.offset < rhs.offset
        }
        .map(\.item)
    }

    private static func compare(_ lhs: TrackSortFields, _ rhs: TrackSortFields, by key: TrackSortKey, ascending: Bool) -> ComparisonResult {
        switch key {
        case .original: return .orderedSame
        case .title: return text(lhs.title, rhs.title, ascending: ascending)
        case .artist: return text(lhs.artist, rhs.artist, ascending: ascending)
        case .album: return text(lhs.album, rhs.album, ascending: ascending)
        case .genre: return text(lhs.genre, rhs.genre, ascending: ascending)
        case .year: return number(Double(lhs.year), Double(rhs.year), ascending: ascending)
        case .duration: return number(lhs.duration, rhs.duration, ascending: ascending)
        case .dateAdded: return number(lhs.dateAdded, rhs.dateAdded, ascending: ascending)
        case .plays: return number(Double(lhs.plays), Double(rhs.plays), ascending: ascending)
        }
    }

    private static func tieBreak(_ lhs: TrackSortFields, _ rhs: TrackSortFields, primary: TrackSortKey) -> ComparisonResult {
        for key in [TrackSortKey.artist, .album] where key != primary {
            let result = compare(lhs, rhs, by: key, ascending: true)
            if result != .orderedSame { return result }
        }
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber ? .orderedAscending : .orderedDescending }
        if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// 沒有資料的永遠排在最後，不論方向
    private static func text(_ lhs: String, _ rhs: String, ascending: Bool) -> ComparisonResult {
        if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty ? .orderedDescending : .orderedAscending }
        let result = lhs.localizedStandardCompare(rhs)
        return ascending ? result : reversed(result)
    }

    private static func number(_ lhs: Double, _ rhs: Double, ascending: Bool) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        if (lhs == 0) != (rhs == 0) { return lhs == 0 ? .orderedDescending : .orderedAscending }
        let result: ComparisonResult = lhs < rhs ? .orderedAscending : .orderedDescending
        return ascending ? result : reversed(result)
    }

    private static func reversed(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

enum AlbumSortKey: String, CaseIterable, Identifiable {
    case title, artist, year, dateAdded, sampleRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return String(localized: "標題")
        case .artist: return String(localized: "field.artist", defaultValue: "歌手")
        case .year: return String(localized: "年份")
        case .dateAdded: return String(localized: "加入日期")
        case .sampleRate: return String(localized: "取樣率")
        }
    }

    func sorted(_ albums: [AlbumGroup]) -> [AlbumGroup] {
        switch self {
        // 分類由 AlbumRateSections 負責，每一類裡依標題排
        case .title, .sampleRate:
            return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return albums.sorted {
                let order = $0.artist.localizedStandardCompare($1.artist)
                return order == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : order == .orderedAscending
            }
        case .year:
            return albums.sorted { $0.year == $1.year ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.year > $1.year }
        case .dateAdded:
            return albums.sorted { $0.addedAt > $1.addedAt }
        }
    }
}
