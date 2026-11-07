//
//  AlbumMerge.swift
//  LosslessCompanion
//
//  專輯以資料夾分組，同一張專輯分在幾個資料夾時可以合併顯示。紀錄存在本機，檔案不動；
//  也可以選擇真的搬到同一個資料夾。
//

import Combine
import Foundation

struct AlbumMerge: Codable, Equatable {
    /// 第一個資料夾是主專輯，順序就是播放順序
    var folders: [String]
    var title: String?

    var target: String { folders[0] }
}

struct AlbumMerges: Codable, Equatable {
    private(set) var merges = [String: AlbumMerge]()

    private var owners: [String: String] {
        var owners = [String: String]()
        for merge in merges.values {
            for folder in merge.folders { owners[folder] = merge.target }
        }
        return owners
    }

    /// 查表用的快照，分組時每一首都要問一次
    var lookup: AlbumMergeLookup { AlbumMergeLookup(owners: owners, merges: merges) }

    func merge(containing folder: String) -> AlbumMerge? {
        owners[folder].flatMap { merges[$0] }
    }

    /// 來源本身已經是合併過的專輯時，它的資料夾全部併進來
    mutating func merge(target: String, sources: [String], title: String?) {
        var folders = merges[target]?.folders ?? [target]
        for source in sources where source != target {
            let group = merges.removeValue(forKey: source)?.folders ?? [source]
            folders += group.filter { !folders.contains($0) }
        }
        merges[target] = AlbumMerge(folders: folders, title: title)
    }

    mutating func split(target: String) {
        merges[target] = nil
    }

    /// 復原單次合併：之前就併進來的資料夾留著
    mutating func remove(folders: [String], from target: String) {
        guard var merge = merges[target] else { return }
        merge.folders.removeAll(where: folders.contains)
        merges[target] = merge.folders.count > 1 ? merge : nil
    }
}

struct AlbumMergeLookup {
    fileprivate var owners = [String: String]()
    fileprivate var merges = [String: AlbumMerge]()

    func group(of folder: String) -> String {
        owners[folder] ?? folder
    }

    func merge(for group: String) -> AlbumMerge? {
        merges[group]
    }
}

final class AlbumMergeStore: ObservableObject {
    @Published private(set) var merges = AlbumMerges() {
        didSet { save() }
    }

    private let fileURL: URL

    init(directory: URL = AppPaths.support) {
        fileURL = directory.appendingPathComponent("album-merges-v1.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(AlbumMerges.self, from: data) {
            merges = saved
        }
    }

    func merge(target: String, sources: [String], title: String?) {
        merges.merge(target: target, sources: sources, title: title)
    }

    func split(target: String) {
        merges.split(target: target)
    }

    func remove(folders: [String], from target: String) {
        merges.remove(folders: folders, from: target)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(merges) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum AlbumMergePlanner {
    /// 檔名或音軌重複時放進 Disc N 子資料夾：不會撞名，分組時也還是同一張專輯，
    /// 否則兩個部分的第 1 軌會排在一起
    static func moves(into target: AlbumGroup, from sources: [AlbumGroup],
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [FileMove] {
        var names = Set(target.tracks.map { FileNamer.identity($0.url.lastPathComponent) })
        var numbers = Set(target.tracks.filter { $0.trackNumber > 0 }.map { [$0.discNumber, $0.trackNumber] })
        var disc = 2
        var moves = [FileMove]()

        for source in sources {
            let folders = Dictionary(grouping: source.tracks, by: \.folder)
            for name in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let tracks = folders[name] ?? []
                let trackNames = tracks.map { FileNamer.identity($0.url.lastPathComponent) }
                let trackNumbers = tracks.filter { $0.trackNumber > 0 }.map { [$0.discNumber, $0.trackNumber] }
                var folder = URL(fileURLWithPath: target.id)
                if trackNames.contains(where: names.contains) || trackNumbers.contains(where: numbers.contains) {
                    while exists(folder.appendingPathComponent("Disc \(disc)").path) { disc += 1 }
                    folder.appendPathComponent("Disc \(disc)")
                    disc += 1
                }
                else {
                    names.formUnion(trackNames)
                    numbers.formUnion(trackNumbers)
                }
                moves += tracks.map { FileMove(from: $0.path, to: folder.appendingPathComponent($0.url.lastPathComponent).path) }
            }
        }
        return moves
    }

    /// 同一張專輯的另一份資料夾排在前面，通常就是想合併的那些
    static func candidates(for album: AlbumGroup, in albums: [AlbumGroup]) -> [AlbumGroup] {
        let title = TrackMatcher.albumKey(album.title)
        let artist = SearchText.normalize(album.artist)
        func rank(_ other: AlbumGroup) -> Int {
            let sameTitle = TrackMatcher.sameAlbum(title, TrackMatcher.albumKey(other.title))
            let sameArtist = SearchText.normalize(other.artist) == artist
            if sameTitle { return sameArtist ? 0 : 1 }
            return sameArtist ? 2 : 3
        }
        let ranked: [(album: AlbumGroup, rank: Int)] = albums.filter { $0.id != album.id }.map { ($0, rank($0)) }
        let ordered = ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.album.title.localizedStandardCompare(rhs.album.title) == .orderedAscending
        }
        return ordered.map(\.album)
    }

    /// 兩邊歌名相同的曲目數，通常代表是同一張專輯的另一個版本，合併後會重複
    static func duplicateCount(in albums: [AlbumGroup]) -> Int {
        var seen = Set<String>()
        var duplicates = 0
        for track in albums.flatMap(\.tracks) where !seen.insert(track.titleKey).inserted { duplicates += 1 }
        return duplicates
    }
}
