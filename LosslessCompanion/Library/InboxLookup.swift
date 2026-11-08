//
//  InboxLookup.swift
//  LosslessCompanion
//
//  替收件匣的歌找 Apple Music 的資料：先找使用者的 Music 資料庫，找不到再查 Apple 公開的目錄。
//  比對沿用 TrackMatcher，歌名、歌手與長度都要對得上。
//

import Foundation

struct InboxLookupResult {
    let entry: MusicPlaylistEntry
    let source: InboxSource
    let artworkURL: String?
}

enum InboxLookup {
    /// 回傳路徑 → 最符合的資料庫歌曲
    static func matchLibrary(_ tracks: [LibraryTrack], entries: [MusicPlaylistEntry]) -> [String: MusicPlaylistEntry] {
        guard !tracks.isEmpty else { return [:] }
        let matcher = TrackMatcher(tracks: tracks)
        let durations = tracks.map(\.duration)
        var best = [String: (entry: MusicPlaylistEntry, confidence: LocalMatch.Confidence)]()
        for entry in entries where durations.contains(where: { abs($0 - entry.duration) <= TrackMatcher.sameReleaseTolerance }) {
            guard let match = matcher.match(entry) else { continue }
            let path = match.track.path
            if let current = best[path] {
                if match.confidence < current.confidence { continue }
                // 同樣可靠時選資料比較完整的，例如有類型與年份的那一筆
                if match.confidence == current.confidence, completeness(entry) <= completeness(current.entry) { continue }
            }
            best[path] = (entry, match.confidence)
        }
        return best.mapValues(\.entry)
    }

    private static func completeness(_ entry: MusicPlaylistEntry) -> Int {
        [entry.genre?.isEmpty == false, entry.year > 0, entry.trackNumber > 0, !entry.albumArtist.isEmpty].filter { $0 }.count
    }

    // MARK: Apple Music catalog

    /// 依序查本地區、日本與美國的商店，第一個對得上的就用
    static func searchCatalog(for track: LibraryTrack, session: URLSession = .shared) -> InboxLookupResult? {
        let artist = (track.albumArtist?.isEmpty == false ? track.albumArtist! : track.artist)
        guard !track.title.isEmpty else { return nil }
        let term = [artist, track.title].filter { !$0.isEmpty }.joined(separator: " ")
        var countries = [Locale.current.region?.identifier ?? "TW", "TW", "JP", "US"]
        countries = countries.enumerated().filter { countries.firstIndex(of: $0.element) == $0.offset }.map(\.element)

        let matcher = TrackMatcher(tracks: [track])
        for country in countries {
            guard let results = search(term: term, country: country, session: session) else { continue }
            for result in results {
                if matcher.match(result.entry) != nil { return result }
            }
        }
        return nil
    }

    static func search(term: String, country: String, session: URLSession) -> [InboxLookupResult]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        done.wait()
        return body.map(parse)
    }

    static func parse(_ data: Data) -> [InboxLookupResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.enumerated().compactMap { index, item in
            guard item["wrapperType"] as? String ?? "track" == "track",
                  let title = item["trackName"] as? String,
                  let millis = item["trackTimeMillis"] as? Double else { return nil }
            let artist = item["artistName"] as? String ?? ""
            let release = item["releaseDate"] as? String ?? ""
            let entry = MusicPlaylistEntry(
                position: index,
                trackID: "catalog-\(item["trackId"] as? Int ?? index)",
                title: title,
                artist: artist,
                albumArtist: item["collectionArtistName"] as? String ?? "",
                album: item["collectionName"] as? String ?? "",
                duration: millis / 1000,
                trackNumber: item["trackNumber"] as? Int ?? 0,
                discNumber: item["discNumber"] as? Int ?? 0,
                year: Int(release.prefix(4)) ?? 0,
                cloudStatus: "",
                genre: item["primaryGenreName"] as? String
            )
            let artwork = (item["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
            return InboxLookupResult(entry: entry, source: .appleCatalog, artworkURL: artwork)
        }
    }
}
