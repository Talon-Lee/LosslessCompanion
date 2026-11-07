//
//  PlaybackModels.swift
//  LosslessCompanion
//

import Combine
import Foundation

enum PlaybackRoute: String, Codable {
    /// 自己解碼並獨佔 DAC，Bit-Perfect
    case local
    /// 由 Apple Music 播放，只做取樣率匹配
    case appleMusic
}

/// 播放列表要怎麼選擇來源。混合模式在本地與串流之間切換時要交接 DAC，會有數秒空檔
enum RoutePreference: String, Codable, CaseIterable, Identifiable {
    case preferLocal
    case localOnly
    case appleMusicOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferLocal: return String(localized: "本地優先")
        case .localOnly: return String(localized: "只播本地")
        case .appleMusicOnly: return String(localized: "只用 Apple Music")
        }
    }

    var detail: String {
        switch self {
        case .preferLocal: return String(localized: "有本地檔案就走獨佔，其餘串流；來源切換時會有數秒空檔")
        case .localOnly: return String(localized: "只播有本地檔案的歌曲，全程獨佔，同規格可無縫接續")
        case .appleMusicOnly: return String(localized: "全部交給 Apple Music 串流，不使用獨佔")
        }
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

struct StreamReference: Hashable {
    let playlistID: String
    let trackID: String
}

struct QueueItem: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let route: PlaybackRoute
    let local: LibraryTrack?
    let stream: StreamReference?
}

extension QueueItem {
    init(track: LibraryTrack, id: String? = nil) {
        self.init(id: id ?? track.path, title: track.title, artist: track.artist, album: track.album,
                  duration: track.duration, route: .local, local: track, stream: nil)
    }

    init(entry: MusicPlaylistEntry, playlistID: String, match: LibraryTrack?, route: PlaybackRoute) {
        self.init(id: "\(playlistID)-\(entry.id)", title: entry.title, artist: entry.artist, album: entry.album,
                  duration: entry.duration, route: route, local: match,
                  stream: StreamReference(playlistID: playlistID, trackID: entry.trackID))
    }
}

/// 待播清單的三段。沒有正在播的歌時，全部都算接下來
struct QueueSections: Equatable {
    let played: Range<Int>
    let current: Int?
    let upcoming: Range<Int>

    init(count: Int, currentIndex: Int?) {
        if let currentIndex, (0..<count).contains(currentIndex) {
            played = 0..<currentIndex
            current = currentIndex
            upcoming = (currentIndex + 1)..<count
        }
        else {
            played = 0..<0
            current = nil
            upcoming = 0..<count
        }
    }

    /// 拖曳放開時落在哪一列：每移動一列高度換一格，只能落在接下來這一段
    func dropIndex(from index: Int, offset: Double, rowHeight: Double) -> Int {
        let steps = Int((offset / rowHeight).rounded())
        return min(max(index + steps, upcoming.lowerBound), upcoming.upperBound - 1)
    }

    /// 拖曳中其他列要往哪邊讓開一列：-1 往上，1 往下
    static func shift(of index: Int, draggingFrom source: Int, to target: Int) -> Int {
        if index > source && index <= target { return -1 }
        if index < source && index >= target { return 1 }
        return 0
    }
}

enum QueueBuilder {
    /// 回傳佇列與起始位置；「只播本地」時沒有本地檔案的歌曲不會進佇列
    static func items(for playlist: MusicPlaylist, entries: [MusicPlaylistEntry]? = nil, startingAt start: MusicPlaylistEntry?,
                      preference: RoutePreference, forcedRoute: PlaybackRoute? = nil,
                      match: (MusicPlaylistEntry) -> LibraryTrack?) -> (items: [QueueItem], index: Int) {
        var items = [QueueItem]()
        var startIndex = 0
        for entry in entries ?? playlist.entries {
            let local = match(entry)
            let stream: PlaybackRoute? = entry.isStreamable ? .appleMusic : nil
            var route: PlaybackRoute?
            switch preference {
            case .preferLocal: route = local == nil ? stream : .local
            case .localOnly: route = local == nil ? nil : .local
            case .appleMusicOnly: route = stream
            }
            if entry == start, let forcedRoute {
                route = forcedRoute == .local ? (local == nil ? route : .local) : (stream ?? route)
            }
            guard let route else { continue }
            if entry == start { startIndex = items.count }
            items.append(QueueItem(entry: entry, playlistID: playlist.id, match: local, route: route))
        }
        return (items, startIndex)
    }
}

/// 播放位置更新很頻繁，獨立出來才不會讓整個歌單畫面跟著重算
final class PlaybackClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

struct TrackVerification: Equatable {
    let title: String
    let passed: Bool
    /// 也和 FLAC 檔案內建的 MD5 相符，代表解碼結果就是原始音訊
    let matchedFile: Bool
}

// MARK: - Transports

/// 回呼一律在主執行緒執行，索引是相對於 play 傳入的曲目
protocol LocalTransport: AnyObject {
    var onTrackStarted: ((Int, AudioSourceFormat, OutputPath) -> Void)? { get set }
    var onPosition: ((Int, Int64) -> Void)? { get set }
    var onVerified: ((Int, TrackResult) -> Void)? { get set }
    /// 參數是引擎實際播到的最後一首
    var onFinished: ((Int) -> Void)? { get set }
    var onInterrupted: ((String) -> Void)? { get set }

    func play(tracks: [LibraryTrack], deviceUID: String, completion: @escaping (Error?) -> Void)
    func setPaused(_ paused: Bool)
    func seek(toFrame frame: Int64)
    func skip(toIndex index: Int)
    /// 換掉 index 之後的曲目，正在播的歌不受影響
    func replaceUpcoming(after index: Int, with tracks: [LibraryTrack])
    func stop(completion: @escaping () -> Void)
    /// App 結束時用，返回時 DAC 已還原
    func stopAndWait()
}

enum StreamEvent: Equatable {
    case playing(trackID: String?)
    case paused(trackID: String?)
    case stopped
}

protocol StreamTransport: AnyObject {
    /// 主執行緒回呼
    var onEvent: ((StreamEvent) -> Void)? { get set }
    /// 位置與 Music 目前的歌曲
    var onProgress: ((TimeInterval, String?) -> Void)? { get set }
    /// Music 最後回報的狀態是已停止
    var isStopped: Bool { get }

    func play(_ reference: StreamReference, completion: @escaping (Error?) -> Void)
    func resume()
    /// 確定 Music 已停止輸出才回呼，之後才能接手 DAC
    func pauseIfPlaying(completion: @escaping () -> Void)
    func seek(to seconds: TimeInterval)
    func setPositionPolling(_ enabled: Bool)
}
