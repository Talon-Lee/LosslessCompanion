//
//  PlaylistStore.swift
//  LosslessCompanion
//
//  保存 Apple Music 播放列表與資料庫的副本。Music 沒開時用上次的結果，不會為了同步把它叫起來。
//

import Combine
import Foundation

final class PlaylistStore: ObservableObject {
    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    @Published private(set) var playlists = [MusicPlaylist]()
    @Published private(set) var library = [MusicPlaylistEntry]()
    @Published private(set) var syncState = SyncState.idle
    @Published private(set) var lastSynced: Date?

    private let playlistsURL: URL
    private let libraryURL: URL
    private let runner: MusicScriptRunner

    private static let staleInterval: TimeInterval = 300

    init(directory: URL = AppPaths.support, runner: MusicScriptRunner = .shared) {
        playlistsURL = directory.appendingPathComponent("playlists-v1.json")
        libraryURL = directory.appendingPathComponent("music-library-v1.json")
        self.runner = runner
        loadCache()
    }

    func playlist(id: String) -> MusicPlaylist? {
        playlists.first { $0.id == id }
    }

    func syncIfStale() {
        if let lastSynced, Date().timeIntervalSince(lastSynced) < Self.staleInterval { return }
        sync()
    }

    func sync() {
        guard syncState != .syncing, runner.isMusicRunning else { return }
        syncState = .syncing
        runner.runInSubprocess(MusicScripts.readLibrary) { [weak self] result in
            let snapshot = (try? result.get()).map { MusicPlaylistParser.parse($0.trimmingCharacters(in: .newlines)) }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    self.syncState = .failed(error.localizedDescription)
                    return
                }
                if let snapshot { self.apply(snapshot) }
                self.syncState = .idle
            }
        }
    }

    /// 回傳空的結果多半是讀取失敗，不能拿它覆蓋現有資料
    private func apply(_ snapshot: MusicSnapshot) {
        guard !snapshot.playlists.isEmpty else { return }
        playlists = snapshot.playlists
        if !snapshot.library.isEmpty { library = snapshot.library }
        lastSynced = Date()
        saveCache()
    }

    private func loadCache() {
        if let data = try? Data(contentsOf: playlistsURL),
           let cached = try? JSONDecoder().decode([MusicPlaylist].self, from: data) {
            playlists = cached
        }
        if let data = try? Data(contentsOf: libraryURL),
           let cached = try? JSONDecoder().decode([MusicPlaylistEntry].self, from: data) {
            library = cached
        }
    }

    private func saveCache() {
        let playlists = self.playlists
        let library = self.library
        let directory = playlistsURL.deletingLastPathComponent()
        let playlistsURL = self.playlistsURL
        let libraryURL = self.libraryURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: playlistsURL, options: .atomic) }
            if let data = try? JSONEncoder().encode(library) { try? data.write(to: libraryURL, options: .atomic) }
        }
    }

    #if DEBUG
    func debugReplace(_ snapshot: MusicSnapshot) {
        playlists = snapshot.playlists
        library = snapshot.library
    }
    #endif
}
