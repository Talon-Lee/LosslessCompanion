//
//  MatchReview.swift
//  LosslessCompanion
//
//  手動校閱。自動比對寧可漏掉也不配錯，漏掉的由使用者確認；
//  決定存在本機，重新掃描或同步 Apple Music 都不會消失。
//

import Combine
import Foundation

/// 保留歌曲文字：同一首歌在訂閱歌單裡的 persistent ID 可能和資料庫不同
struct ManualLink: Codable, Hashable {
    var path: String
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    init(track: LibraryTrack, entry: MusicPlaylistEntry) {
        path = track.path
        trackID = entry.trackID
        title = entry.title
        artist = entry.artist
        album = entry.album
        duration = entry.duration
    }

    static func songKey(title: String, artist: String, album: String) -> String {
        SearchText.normalize([title, artist, album].joined(separator: "\n"))
    }
}

struct MatchDecisions: Codable, Equatable {
    /// 以本地檔案路徑為索引
    private(set) var links = [String: ManualLink]()
    private(set) var localOnly = Set<String>()

    var isEmpty: Bool { links.isEmpty && localOnly.isEmpty }

    /// 一首歌只對應一個檔案，後來的決定取代先前的
    mutating func link(_ track: LibraryTrack, to entry: MusicPlaylistEntry) {
        links = links.filter { $0.value.trackID != entry.trackID }
        links[track.path] = ManualLink(track: track, entry: entry)
        localOnly.remove(track.path)
    }

    mutating func link(_ pairs: [(track: LibraryTrack, entry: MusicPlaylistEntry)]) {
        pairs.forEach { link($0.track, to: $0.entry) }
    }

    mutating func markLocalOnly(_ path: String) {
        links[path] = nil
        localOnly.insert(path)
    }

    mutating func undo(_ path: String) {
        links[path] = nil
        localOnly.remove(path)
    }

    /// 決定以路徑為索引，檔案改名後要跟著換，否則連結會失效
    mutating func apply(_ moves: [FileMove]) {
        for move in moves {
            if var link = links.removeValue(forKey: move.from) {
                link.path = move.to
                links[move.to] = link
            }
            if localOnly.remove(move.from) != nil { localOnly.insert(move.to) }
        }
    }
}

enum ReviewStatus: Equatable {
    case automatic
    case unmatched
    case linked(ManualLink)
    case localOnly
}

final class MatchReviewStore: ObservableObject {
    @Published private(set) var decisions = MatchDecisions() {
        didSet { save() }
    }

    private let fileURL: URL

    init(directory: URL = AppPaths.support) {
        fileURL = directory.appendingPathComponent("match-review-v1.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(MatchDecisions.self, from: data) {
            decisions = saved
        }
    }

    func link(_ track: LibraryTrack, to entry: MusicPlaylistEntry) {
        decisions.link(track, to: entry)
    }

    /// 一次改完才寫檔與重建，不會一首觸發一次
    func link(_ pairs: [(track: LibraryTrack, entry: MusicPlaylistEntry)]) {
        decisions.link(pairs)
    }

    func markLocalOnly(_ track: LibraryTrack) {
        decisions.markLocalOnly(track.path)
    }

    func markLocalOnly(_ tracks: [LibraryTrack]) {
        var updated = decisions
        tracks.forEach { updated.markLocalOnly($0.path) }
        decisions = updated
    }

    func undo(_ path: String) {
        decisions.undo(path)
    }

    func clearAll() {
        decisions = MatchDecisions()
    }

    func apply(_ moves: [FileMove]) {
        var updated = decisions
        updated.apply(moves)
        decisions = updated
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Applying decisions

struct MatchResolution {
    var matches = [String: LocalMatch]()
    /// 本地路徑對應到的 Music 歌曲
    var apple = [String: MusicPlaylistEntry]()
    var favorites = Set<String>()
}

enum MatchResolver {
    /// 手動連結優先於自動比對。檔案已移走的連結不生效，歌曲維持串流
    static func resolve(tracks: [LibraryTrack], entries: [MusicPlaylistEntry], decisions: MatchDecisions) -> MatchResolution {
        let matcher = TrackMatcher(tracks: tracks)
        let links = Array(decisions.links.values)
        let linkedByID = Dictionary(links.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        let linkedBySong = Dictionary(links.map { (ManualLink.songKey(title: $0.title, artist: $0.artist, album: $0.album), $0) },
                                      uniquingKeysWith: { first, _ in first })
        let tracksByPath = links.isEmpty ? [:] : Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var resolution = MatchResolution()
        for entry in entries {
            let link = links.isEmpty ? nil
                : linkedByID[entry.trackID] ?? linkedBySong[ManualLink.songKey(title: entry.title, artist: entry.artist, album: entry.album)]
            let match = link.flatMap { tracksByPath[$0.path] }.map { LocalMatch(track: $0, confidence: .manual) } ?? matcher.match(entry)
            guard let match else { continue }
            resolution.matches[entry.trackID] = match
            if resolution.apple[match.track.path] == nil { resolution.apple[match.track.path] = entry }
            if entry.isFavorite == true { resolution.favorites.insert(match.track.path) }
        }
        return resolution
    }

    /// 同一首歌硬碟上有兩份時，自動比對只選一份，另一份會留在未匹配。
    /// 回傳這些檔案與被選中的那一份，它們其實不缺對應的歌曲
    static func duplicates(in tracks: [LibraryTrack], scores: [String: Int], suggester: MatchSuggester,
                           matches: [String: LocalMatch]) -> [String: LibraryTrack] {
        var result = [String: LibraryTrack]()
        for track in tracks where (scores[track.path] ?? 0) >= MatchSuggester.certainScore {
            guard let best = suggester.suggestions(for: track, limit: 1).first, best.isCertain,
                  let kept = matches[best.entry.trackID]?.track, kept.path != track.path else { continue }
            result[track.path] = kept
        }
        return result
    }
}

// MARK: - Suggestions

struct MatchSuggestion: Identifiable, Equatable {
    let entry: MusicPlaylistEntry
    let score: Int
    let reasons: [String]
    /// 版本不同（Live、Remix 等）時分數再高也只能由使用者自己決定
    var isSameVersion = true

    var id: String { entry.trackID }
    var isLikely: Bool { isSameVersion && score >= MatchSuggester.likelyScore }
    var isCertain: Bool { isSameVersion && score >= MatchSuggester.certainScore }
}

/// 找出自動比對不敢確定的候選。歌名相同但長度或歌手對不上、譯名不同但專輯與長度相同，都在這裡浮現
/// 校閱時每個決定都會重建索引，但候選只和 Music 資料庫與本地標籤有關，分數算過就不必再算。
/// 只在比對的佇列上使用
final class MatchSuggestionCache {
    private(set) var suggester = MatchSuggester()
    private var entries = [MusicPlaylistEntry]()
    private var tracks = [LibraryTrack]()
    private var scores = [String: Int?]()

    func update(entries: [MusicPlaylistEntry], tracks: [LibraryTrack]) {
        if entries != self.entries {
            self.entries = entries
            suggester = MatchSuggester(entries: entries)
            scores = [:]
        }
        if tracks != self.tracks {
            self.tracks = tracks
            scores = [:]
        }
    }

    func scores(for tracks: [LibraryTrack]) -> [String: Int] {
        var result = [String: Int]()
        for track in tracks {
            let score: Int?
            if let known = scores[track.path] {
                score = known
            }
            else {
                score = suggester.bestScore(for: track)
                scores[track.path] = .some(score)
            }
            if let score { result[track.path] = score }
        }
        return result
    }
}

final class MatchSuggester {
    static let minimumScore = 40
    static let likelyScore = 75
    /// 歌名、歌手、專輯與長度全部相符，才允許一次套用
    static let certainScore = 100

    private enum Points {
        static let sameTitle = 50
        static let similarTitle = 25
        static let sameArtist = 25
        static let sameAlbum = 15
        static let sameTrackNumber = 10
        static let sameLength = 10
        static let closeLength = 5
        static let distantLength = -15
        static let otherVersion = -10
    }

    private static let closeLength: TimeInterval = 6
    private static let distantLength: TimeInterval = 20
    private static let similarTitleThreshold = 0.5

    private struct Candidate {
        let entry: MusicPlaylistEntry
        let fingerprint: TitleFingerprint
        let artists: Set<String>
        let album: String
        let searchKey: String
    }

    private struct Subject {
        let track: LibraryTrack
        let fingerprint: TitleFingerprint
        let artists: Set<String>
        let album: String
    }

    private let candidates: [Candidate]
    private var byTitle = [String: [Int]]()
    private var byArtist = [String: [Int]]()
    private var byAlbum = [String: [Int]]()

    /// entries 不可重複，同一首歌只列一次
    init(entries: [MusicPlaylistEntry] = []) {
        candidates = entries.map { entry in
            Candidate(entry: entry,
                      fingerprint: TitleFingerprint(title: entry.title),
                      artists: TrackMatcher.artistSet(entry.artist).union(TrackMatcher.artistSet(entry.albumArtist)),
                      album: TrackMatcher.albumKey(entry.album),
                      searchKey: SearchText.normalize([entry.title, entry.artist, entry.album].joined(separator: "\n")))
        }
        for (index, candidate) in candidates.enumerated() {
            byTitle[candidate.fingerprint.core, default: []].append(index)
            candidate.artists.forEach { byArtist[$0, default: []].append(index) }
            if !candidate.album.isEmpty { byAlbum[candidate.album, default: []].append(index) }
        }
    }

    func suggestions(for track: LibraryTrack, limit: Int = 8) -> [MatchSuggestion] {
        let subject = Self.subject(for: track)
        var pool = Set(byTitle[subject.fingerprint.core] ?? [])
        pool.formUnion(byAlbum[subject.album] ?? [])
        subject.artists.forEach { pool.formUnion(byArtist[$0] ?? []) }
        return Self.ranked(pool.map { evaluate(candidates[$0], for: subject) }.filter { $0.score >= Self.minimumScore }, limit: limit)
    }

    /// 使用者自己搜尋時不設門檻，自己輸入的就是想看的
    func search(_ query: String, for track: LibraryTrack, limit: Int = 40) -> [MatchSuggestion] {
        let tokens = SearchText.tokens(of: query)
        guard !tokens.isEmpty else { return [] }
        let subject = Self.subject(for: track)
        let found = candidates.filter { candidate in tokens.allSatisfy { candidate.searchKey.contains($0) } }
        return Self.ranked(found.map { evaluate($0, for: subject) }, limit: limit)
    }

    func bestScore(for track: LibraryTrack) -> Int? {
        suggestions(for: track, limit: 1).first?.score
    }

    private static func subject(for track: LibraryTrack) -> Subject {
        Subject(track: track,
                fingerprint: TitleFingerprint(title: track.title),
                artists: TrackMatcher.artistSet(track.artist).union(TrackMatcher.artistSet(track.albumArtist ?? "")),
                album: TrackMatcher.albumKey(track.album))
    }

    private static func ranked(_ suggestions: [MatchSuggestion], limit: Int) -> [MatchSuggestion] {
        Array(suggestions.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
        }.prefix(limit))
    }

    private func evaluate(_ candidate: Candidate, for subject: Subject) -> MatchSuggestion {
        var score = 0
        var reasons = [String]()

        if candidate.fingerprint.core == subject.fingerprint.core {
            score += Points.sameTitle
            reasons.append(String(localized: "歌名相同"))
        }
        else if Self.titleSimilarity(candidate.fingerprint.core, subject.fingerprint.core) >= Self.similarTitleThreshold {
            score += Points.similarTitle
            reasons.append(String(localized: "歌名相近"))
        }

        if TrackMatcher.overlaps(candidate.artists, subject.artists) {
            score += Points.sameArtist
            reasons.append(String(localized: "歌手相同"))
        }

        let sameAlbum = !candidate.album.isEmpty && TrackMatcher.sameAlbum(candidate.album, subject.album)
        if sameAlbum {
            score += Points.sameAlbum
            reasons.append(String(localized: "專輯相同"))
            if subject.track.trackNumber > 0, candidate.entry.trackNumber == subject.track.trackNumber {
                score += Points.sameTrackNumber
                reasons.append(String(localized: "音軌相同"))
            }
        }

        let difference = abs(candidate.entry.duration - subject.track.duration)
        if difference <= TrackMatcher.durationTolerance {
            score += Points.sameLength
            reasons.append(String(localized: "長度相同"))
        }
        else if difference <= Self.closeLength {
            score += Points.closeLength
            reasons.append(String(localized: "長度差 \(Int(difference.rounded())) 秒"))
        }
        else if difference > Self.distantLength {
            score += Points.distantLength
            reasons.append(String(localized: "長度差 \(Int(difference.rounded())) 秒"))
        }

        let isSameVersion = candidate.fingerprint.versions == subject.fingerprint.versions
            && candidate.fingerprint.details == subject.fingerprint.details
        if !isSameVersion {
            score += Points.otherVersion
            reasons.append(String(localized: "版本可能不同"))
        }
        return MatchSuggestion(entry: candidate.entry, score: score, reasons: reasons, isSameVersion: isSameVersion)
    }

    /// 字元雙連組的 Dice 係數，對語序和少數字差異不敏感
    private static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return 2 * Double(left.intersection(right).count) / Double(left.count + right.count)
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }
}
