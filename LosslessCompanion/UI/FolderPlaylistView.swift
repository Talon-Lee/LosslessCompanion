//
//  FolderPlaylistView.swift
//  LosslessCompanion
//

import AppKit
import SwiftUI

struct FolderPlaylistView: View {
    let playlist: FolderPlaylist

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var store: FolderPlaylistStore
    @State private var isRenaming = false
    @State private var draftName = ""

    private static let coverLimit = 4

    /// 每張專輯取一張，湊滿四格
    private func covers(_ tracks: [LibraryTrack]) -> [ArtworkSource] {
        var seen = Set<String>()
        var sources = [ArtworkSource]()
        for track in tracks where seen.insert(track.folder).inserted {
            sources.append(.local(track))
            if sources.count == Self.coverLimit { break }
        }
        return sources
    }

    private func albums(_ tracks: [LibraryTrack]) -> [AlbumGroup] {
        var seen = Set<String>()
        return tracks.compactMap { model.index.albumsByPath[$0.path] }.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let tracks = FolderPlaylistPlanner.tracks(in: playlist.folder, from: library.tracks)
        let covers = covers(tracks)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                DetailHeader(title: playlist.name) {
                    PlaylistCover(sources: covers, side: Theme.coverSide)
                } details: {
                    Text("本地資料夾")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(tracks.count) 首歌曲，\(Format.longDuration(tracks.reduce(0) { $0 + $1.duration }))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } actions: {
                    Button {
                        model.play(tracks: tracks)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    .disabled(tracks.isEmpty)
                    Button {
                        model.play(tracks: tracks, shuffled: true)
                    } label: {
                        Label("隨機播放", systemImage: "shuffle")
                    }
                    .buttonStyle(SecondaryPillStyle())
                    .fixedSize()
                    .disabled(tracks.isEmpty)
                    MoreMenu {
                        Button("下一首播放") { model.playNext(tracks: tracks) }
                        Button("加入待播清單") { model.enqueue(tracks: tracks) }
                        Divider()
                        Button("重新命名…") {
                            draftName = playlist.name
                            isRenaming = true
                        }
                        Button("輸出打包…") {
                            navigation.exportRequest = ExportSheetRequest(title: playlist.name, albums: albums(tracks))
                        }
                        Button("在 Finder 中顯示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: playlist.folder)])
                        }
                        Divider()
                        Button("移除播放列表") { model.removeFolderPlaylist(playlist) }
                    }
                }

                if tracks.isEmpty {
                    ContentUnavailableView("這個資料夾目前沒有可播放的音檔", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                else {
                    LocalTrackList(tracks: tracks, sortKey: "folder.\(playlist.id)")
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) {
            ArtworkBackdrop(source: covers.first ?? .none)
        }
        .alert("重新命名播放列表", isPresented: $isRenaming) {
            TextField("名稱", text: $draftName)
            Button("取消", role: .cancel) {}
            Button("儲存") { store.rename(id: playlist.id, to: draftName) }
        }
    }
}
