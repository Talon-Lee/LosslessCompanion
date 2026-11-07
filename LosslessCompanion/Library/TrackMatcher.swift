//
//  TrackMatcher.swift
//  LosslessCompanion
//
//  把 Apple Music 的歌曲對應到本地無損檔案。Music 的腳本介面沒有 ISRC，只能比對文字與長度，
//  所以規則偏保守：版本不同或沒有足夠證據就不配對，寧可退回串流也不要播錯版本。
//

import Foundation

struct LocalMatch: Hashable {
    enum Confidence: Int, Comparable {
        /// 歌手與長度相符，或專輯與長度相符
        case strong
        /// 歌名、歌手、專輯與長度都相符
        case exact
        /// 使用者手動確認
        case manual

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let track: LibraryTrack
    let confidence: Confidence
}

/// 歌名拆成主體與版本標記，例如 "Song (Live) [Remastered]" → Song + {live, remaster}
struct TitleFingerprint: Equatable {
    let core: String
    let versions: Set<String>
    /// 括號裡的完整文字，不含客串歌手。兩首都是 Remix 不代表是同一個 Remix，校閱時用這個分辨
    let details: Set<String>

    private static let bracketPattern = try! NSRegularExpression(pattern: #"[(\[（【〔<《「『][^)\]）】〕>》」』]*[)\]）】〕>》」』]"#)
    private static let dashSuffixPattern = try! NSRegularExpression(pattern: #"\s[-–—~]\s.+$"#)
    /// 有些檔案把音軌號寫進歌名，例如 "01. 不知反省"
    private static let leadingNumberPattern = try! NSRegularExpression(pattern: #"^\d{1,3}\s*[.．、]\s*"#)
    private static let featurePattern = try! NSRegularExpression(pattern: #"(^|\s)(feat|ft|featuring|with)[\.\s]"#)
    private static let versionPattern = try! NSRegularExpression(pattern: #"(ver\.?|version|版)"#)

    /// 比對對象都先經過 SearchText.normalize，所以這裡用簡體與片假名
    private static let versionWords: [(tag: String, pattern: NSRegularExpression)] = [
        ("live", #"\blive\b|现场|ライブ|演唱会"#),
        ("acoustic", #"acoustic|不插电|アコースティック"#),
        ("remix", #"\bremix\b|\brmx\b|\bmix\b"#),
        ("instrumental", #"instrumental|\binst\b|off vocal|伴奏|カラオケ|karaoke"#),
        ("remaster", #"remaster"#),
        ("demo", #"\bdemo\b"#),
        ("edit", #"\bedit\b"#),
        ("mono", #"\bmono\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    init(title: String) {
        let folded = SearchText.normalize(title)
        let normalized = Self.leadingNumberPattern.stringByReplacingMatches(in: folded, range: NSRange(folded.startIndex..., in: folded), withTemplate: "")
        var versions = Set<String>()
        for word in Self.versionWords where Self.matches(word.pattern, normalized) {
            versions.insert(word.tag)
        }

        var body = normalized
        var removable = [String]()
        for pattern in [Self.bracketPattern, Self.dashSuffixPattern] {
            let range = NSRange(body.startIndex..., in: body)
            for match in pattern.matches(in: body, range: range) {
                guard let swiftRange = Range(match.range, in: body) else { continue }
                removable.append(String(body[swiftRange]))
            }
        }
        var details = Set<String>()
        for segment in removable {
            let isFeature = Self.matches(Self.featurePattern, segment.trimmingCharacters(in: Self.segmentEdges))
            if !isFeature, versions.isEmpty, Self.matches(Self.versionPattern, segment) {
                versions.insert("ver:" + Self.compact(segment))
            }
            if !isFeature { details.insert(Self.compact(segment)) }
            body = body.replacingOccurrences(of: segment, with: " ")
        }

        let core = Self.compact(body)
        self.core = core.isEmpty ? Self.compact(normalized) : core
        self.versions = versions
        self.details = details
    }

    static func compact(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static let segmentEdges = CharacterSet.whitespaces
        .union(.punctuationCharacters).union(.symbols)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

final class TrackMatcher {
    /// 串流與 CD 版本常差一兩秒的靜音；差更多通常是另一個版本
    static let durationTolerance: TimeInterval = 2.5
    /// 歌手與專輯都相同時，長度差多一點也不會是別首歌
    static let sameReleaseTolerance: TimeInterval = 4
    /// 只有專輯可依靠時（例如古典樂歌手是譯名），長度要更接近
    static let albumOnlyTolerance: TimeInterval = 1.5

    private struct Candidate {
        let track: LibraryTrack
        let versions: Set<String>
        let artists: Set<String>
        let album: String
        let isLiveAlbum: Bool
    }

    private var byTitle = [String: [Candidate]]()

    private static let suffixPattern = try! NSRegularExpression(pattern: #"\s-\s(single|ep)$"#)
    private static let bracketPattern = try! NSRegularExpression(pattern: #"[(\[（【][^)\]）】]*[)\]）】]"#)
    /// 現場專輯的歌名常常不標 Live，要從專輯名稱判斷
    private static let liveAlbumPattern = try! NSRegularExpression(pattern: #"\blive\b|\bconcert\b|\btour\b|现场|演唱会|ライブ"#)
    private static let artistSeparators = try! NSRegularExpression(pattern: #"\s*(,|、|&|/|／|;|；|×|\||\sx\s|\sand\s|\sfeat\.?\s|\sft\.?\s|\swith\s|和)\s*"#)

    init(tracks: [LibraryTrack]) {
        for track in tracks {
            let fingerprint = TitleFingerprint(title: track.title)
            guard !fingerprint.core.isEmpty else { continue }
            byTitle[fingerprint.core, default: []].append(Candidate(track: track,
                                                                    versions: fingerprint.versions,
                                                                    artists: Self.artistSet(track.artist),
                                                                    album: Self.albumKey(track.album),
                                                                    isLiveAlbum: Self.isLiveAlbum(track.album)))
        }
    }

    func match(_ entry: MusicPlaylistEntry) -> LocalMatch? {
        let fingerprint = TitleFingerprint(title: entry.title)
        guard let candidates = byTitle[fingerprint.core], entry.duration > 0 else { return nil }
        let artists = Self.artistSet(entry.artist).union(Self.artistSet(entry.albumArtist))
        let album = Self.albumKey(entry.album)
        let isLive = Self.isLiveAlbum(entry.album)

        var best: (candidate: Candidate, confidence: LocalMatch.Confidence, difference: TimeInterval)?
        for candidate in candidates where candidate.versions == fingerprint.versions && candidate.isLiveAlbum == isLive {
            let difference = abs(candidate.track.duration - entry.duration)
            guard difference <= Self.sameReleaseTolerance else { continue }

            let sameArtist = Self.overlaps(artists, candidate.artists)
            let sameAlbum = !album.isEmpty && Self.sameAlbum(album, candidate.album)

            let confidence: LocalMatch.Confidence
            if sameArtist && sameAlbum { confidence = .exact }
            else if sameArtist && difference <= Self.durationTolerance { confidence = .strong }
            else if sameAlbum && difference <= Self.albumOnlyTolerance { confidence = .strong }
            else { continue }

            if let current = best {
                guard Self.isBetter(candidate, confidence, difference, than: current) else { continue }
            }
            best = (candidate, confidence, difference)
        }
        return best.map { LocalMatch(track: $0.candidate.track, confidence: $0.confidence) }
    }

    private static func isBetter(_ candidate: Candidate, _ confidence: LocalMatch.Confidence, _ difference: TimeInterval,
                                 than current: (candidate: Candidate, confidence: LocalMatch.Confidence, difference: TimeInterval)) -> Bool {
        if confidence != current.confidence { return confidence > current.confidence }
        let lhs = candidate.track.sampleRate * Double(candidate.track.bitsPerSample)
        let rhs = current.candidate.track.sampleRate * Double(current.candidate.track.bitsPerSample)
        if lhs != rhs { return lhs > rhs }
        return difference < current.difference
    }

    static func artistSet(_ text: String) -> Set<String> {
        let normalized = SearchText.normalize(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        let marked = artistSeparators.stringByReplacingMatches(in: normalized, range: range, withTemplate: "\u{1F}")
        return Set(marked.components(separatedBy: "\u{1F}").map(TitleFingerprint.compact).filter { !$0.isEmpty })
    }

    /// 一邊是另一邊的一部分也算相同，例如 "鄧紫棋" 與 "G.E.M. 鄧紫棋"；太短的名字容易誤判
    static func overlaps(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        for left in lhs {
            for right in rhs {
                if left == right { return true }
                let (shorter, longer) = left.count < right.count ? (left, right) : (right, left)
                if shorter.count >= 2, longer.contains(shorter) { return true }
            }
        }
        return false
    }

    static func isLiveAlbum(_ text: String) -> Bool {
        let normalized = SearchText.normalize(text)
        return liveAlbumPattern.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }

    static func albumKey(_ text: String) -> String {
        var key = SearchText.normalize(text)
        key = suffixPattern.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "")
        key = bracketPattern.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "")
        return TitleFingerprint.compact(key)
    }

    static func sameAlbum(_ lhs: String, _ rhs: String) -> Bool {
        guard !rhs.isEmpty else { return false }
        return lhs == rhs || (min(lhs.count, rhs.count) >= 4 && (lhs.contains(rhs) || rhs.contains(lhs)))
    }
}
