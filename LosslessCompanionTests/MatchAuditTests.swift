//
//  MatchAuditTests.swift
//  LosslessCompanionTests
//
//  用真實資料量比對準確度：TEST_RUNNER_LC_MATCH_AUDIT=<放快取副本的資料夾>。只讀副本，不寫任何東西。
//  使用者在校閱時手動連結的歌就是標準答案：自動比對應該要能找到它們，而且不能配到別首。
//

import XCTest
@testable import LosslessCompanion

final class MatchAuditTests: XCTestCase {
    private struct CacheRow: Decodable {
        let path: String
        let track: LibraryTrack?
    }

    func testAuditRealLibrary() throws {
        guard let folder = ProcessInfo.processInfo.environment["LC_MATCH_AUDIT"] else { throw XCTSkip("沒有指定資料") }
        let dir = URL(fileURLWithPath: folder)
        let cache = try JSONDecoder().decode([CacheRow].self, from: Data(contentsOf: dir.appendingPathComponent("library-v1.json")))
        let tracks = cache.compactMap(\.track)
        let library = try JSONDecoder().decode([MusicPlaylistEntry].self, from: Data(contentsOf: dir.appendingPathComponent("music-library-v1.json")))
        let playlists = try JSONDecoder().decode([MusicPlaylist].self, from: Data(contentsOf: dir.appendingPathComponent("playlists-v1.json")))
        let decisions = try JSONDecoder().decode(MatchDecisions.self, from: Data(contentsOf: dir.appendingPathComponent("match-review-v1.json")))
        var seen = Set<String>()
        let entries = (library + playlists.flatMap(\.entries)).filter { seen.insert($0.trackID).inserted }

        let auto = MatchResolver.resolve(tracks: tracks, entries: entries, decisions: MatchDecisions())
        let resolved = MatchResolver.resolve(tracks: tracks, entries: entries, decisions: decisions)
        let matchedPaths = Set(resolved.apple.keys)
        let unmatched = tracks.filter { !matchedPaths.contains($0.path) && !decisions.localOnly.contains($0.path) }
        if let dump = ProcessInfo.processInfo.environment["LC_MATCH_DUMP"] {
            let byID = Dictionary(entries.map { ($0.trackID, $0) }, uniquingKeysWith: { a, _ in a })
            let lines = auto.matches.compactMap { id, match -> String? in
                guard let e = byID[id] else { return nil }
                return "\(id)\t\(e.title) | \(e.artist) | \(e.album) | \(Int(e.duration))\t\(match.track.title) | \(match.track.artist) | \(match.track.album) | \(Int(match.track.duration))"
            }.sorted()
            try lines.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        }
        print("AUDIT tracks=\(tracks.count) entries=\(entries.count) autoMatchedEntries=\(auto.matches.count) autoLocal=\(Set(auto.apple.keys).count) links=\(decisions.links.count) localOnly=\(decisions.localOnly.count) unmatched=\(unmatched.count)")

        // 手動連結：自動比對有沒有找到，找到的是不是同一個檔案
        let byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var missed = 0, wrong = 0, found = 0
        var reasons = [String: Int]()
        for link in decisions.links.values {
            guard let track = byPath[link.path] else { continue }
            let entry = entries.first { $0.trackID == link.trackID }
                ?? entries.first { ManualLink.songKey(title: $0.title, artist: $0.artist, album: $0.album) == ManualLink.songKey(title: link.title, artist: link.artist, album: link.album) }
            guard let entry else { continue }
            if let match = auto.matches[entry.trackID] {
                if match.track.path == track.path { found += 1 } else { wrong += 1; print("AUDIT WRONG \(entry.title) | \(entry.artist) | \(entry.album) -> \(match.track.title) | \(match.track.artist) | \(match.track.album)") }
                continue
            }
            missed += 1
            let lf = TitleFingerprint(title: track.title), ef = TitleFingerprint(title: entry.title)
            var why = [String]()
            if lf.core != ef.core { why.append("title") }
            if lf.versions != ef.versions { why.append("version") }
            let artists = TrackMatcher.artistSet(entry.artist).union(TrackMatcher.artistSet(entry.albumArtist))
            if !TrackMatcher.overlaps(artists, TrackMatcher.artistSet(track.artist).union(TrackMatcher.artistSet(track.albumArtist ?? ""))) { why.append("artist") }
            if !TrackMatcher.sameAlbum(TrackMatcher.albumKey(entry.album), TrackMatcher.albumKey(track.album)) { why.append("album") }
            let diff = abs(track.duration - entry.duration)
            if diff > TrackMatcher.durationTolerance { why.append(diff > 4 ? "length>4" : "length>2.5") }
            if TrackMatcher.isLiveAlbum(entry.album) != TrackMatcher.isLiveAlbum(track.album) { why.append("live") }
            for reason in why { reasons[reason, default: 0] += 1 }
            print("AUDIT MISS [\(why.joined(separator: ","))] L: \(track.title) | \(track.artist) | \(track.album) | \(Int(track.duration))s   A: \(entry.title) | \(entry.artist) | \(entry.album) | \(Int(entry.duration))s")
        }
        print("AUDIT links found=\(found) missed=\(missed) wrong=\(wrong) reasons=\(reasons.sorted { $0.value > $1.value })")

        // 可疑的自動配對：同一個檔案被多首不同專輯的歌配到
        var byLocal = [String: [MusicPlaylistEntry]]()
        for (id, match) in auto.matches { if let entry = entries.first(where: { $0.trackID == id }) { byLocal[match.track.path, default: []].append(entry) } }
        var conflicts = 0
        for (path, list) in byLocal {
            let albums = Set(list.map { TrackMatcher.albumKey($0.album) })
            let titles = Set(list.map { TitleFingerprint(title: $0.title).core })
            guard titles.count > 1 || albums.count > 1, let track = byPath[path] else { continue }
            conflicts += 1
            if conflicts <= 25 { print("AUDIT SHARED \(track.title) | \(track.artist) | \(track.album) <- " + list.map { "\($0.title) | \($0.artist) | \($0.album) | \(Int($0.duration))s" }.joined(separator: "  ||  ")) }
        }
        print("AUDIT sharedLocal=\(conflicts)")

        // 自動配對中歌手不同、只靠專輯與長度的
        var albumOnly = 0
        for (id, match) in auto.matches where match.confidence == .strong {
            guard let entry = entries.first(where: { $0.trackID == id }) else { continue }
            let artists = TrackMatcher.artistSet(entry.artist).union(TrackMatcher.artistSet(entry.albumArtist))
            if !TrackMatcher.overlaps(artists, TrackMatcher.artistSet(match.track.artist).union(TrackMatcher.artistSet(match.track.albumArtist ?? ""))) {
                albumOnly += 1
                if albumOnly <= 15 { print("AUDIT ALBUMONLY \(entry.title) | \(entry.artist) | \(entry.album) -> \(match.track.artist) | \(match.track.album)") }
            }
        }
        print("AUDIT albumOnly=\(albumOnly)")

        // 仍未匹配的檔案：最佳候選的分數
        let suggester = MatchSuggester(entries: entries)
        var buckets = [String: Int]()
        var samples = 0
        for track in unmatched {
            guard let best = suggester.suggestions(for: track, limit: 1).first else { buckets["none", default: 0] += 1; continue }
            let bucket = best.isCertain ? "certain" : best.isLikely ? "likely" : "weak"
            buckets[bucket, default: 0] += 1
            if best.isLikely, samples < 40 {
                samples += 1
                print("AUDIT CAND \(best.score) [\(best.reasons.joined(separator: ","))] L: \(track.title) | \(track.artist) | \(track.album) | \(Int(track.duration))s   A: \(best.entry.title) | \(best.entry.artist) | \(best.entry.album) | \(Int(best.entry.duration))s")
            }
        }
        print("AUDIT unmatchedBuckets=\(buckets)")
    }
}
