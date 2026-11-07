//
//  FolderPlaylists.swift
//  LosslessCompanion
//
//  把音樂庫裡的資料夾變成播放列表。只記資料夾，內容每次從音樂庫算出來，
//  資料夾裡新增或刪除檔案時播放列表會跟著變，也不會動到任何檔案。
//

import Combine
import Foundation

struct FolderPlaylist: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    let folder: String
}

final class FolderPlaylistStore: ObservableObject {
    @Published private(set) var playlists = [FolderPlaylist]() {
        didSet { save() }
    }

    private let fileURL: URL

    init(directory: URL = AppPaths.support) {
        fileURL = directory.appendingPathComponent("folder-playlists-v1.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([FolderPlaylist].self, from: data) {
            playlists = saved
        }
    }

    func playlist(id: String) -> FolderPlaylist? {
        playlists.first { $0.id == id }
    }

    /// 同一個資料夾只有一張，已經有的直接回傳
    @discardableResult
    func add(folder: String) -> FolderPlaylist {
        if let existing = playlists.first(where: { $0.folder == folder }) { return existing }
        let playlist = FolderPlaylist(id: UUID().uuidString, name: URL(fileURLWithPath: folder).lastPathComponent, folder: folder)
        playlists.append(playlist)
        return playlist
    }

    func rename(id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
    }

    func remove(id: String) {
        playlists.removeAll { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum FolderPlaylistPlanner {
    /// 含子資料夾。音樂庫是依音軌排的，直接用的話不同專輯的第 1 軌會排在一起，所以先依資料夾分開
    static func tracks(in folder: String, from tracks: [LibraryTrack]) -> [LibraryTrack] {
        let prefix = LocalLibrary.pathPrefix(of: folder)
        let matched = tracks.filter { $0.path.hasPrefix(prefix) }.map { (track: $0, folder: $0.folder) }
        return matched.sorted { lhs, rhs in
            if lhs.folder != rhs.folder { return lhs.folder.localizedStandardCompare(rhs.folder) == .orderedAscending }
            return LibraryBrowser.playOrder(lhs.track, rhs.track)
        }.map(\.track)
    }

    /// 從這個資料夾往上到音樂庫根目錄之前的每一層。根目錄就是整個音樂庫，不需要再列一次
    static func choices(for folder: String, roots: [String]) -> [String] {
        let prefixes = roots.map(LocalLibrary.pathPrefix)
        var choices = [String]()
        var current = folder
        while prefixes.contains(where: { (current + "/").hasPrefix($0) && current + "/" != $0 }) {
            choices.append(current)
            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        return choices
    }
}
