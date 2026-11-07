//
//  ArtistViews.swift
//  LosslessCompanion
//
//  歌手頁檢視與管理一位歌手在硬碟上的所有檔案，包含別人專輯裡的客串與合輯歌曲。
//

import AppKit
import SwiftUI

/// 歌手名稱。合輯的「群星」不是一位歌手，沒有歌手頁，只顯示文字
struct ArtistLink: View {
    let name: String
    var font = Font.system(size: 12)

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel
    @State private var isHovering = false

    private var label: some View {
        Text(name)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    var body: some View {
        if let artist = model.index.artistsByName[name] {
            Button {
                navigation.open(.artist(artist))
            } label: {
                label.underline(isHovering)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("前往歌手頁面")
            .accessibilityLabel("前往歌手 \(name)")
        }
        else {
            label
        }
    }
}

private enum ArtistPageMode: String, CaseIterable, Identifiable {
    case albums, tracks, folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albums: return String(localized: "專輯")
        case .tracks: return String(localized: "歌曲")
        case .folders: return String(localized: "檔案位置")
        }
    }
}

struct ArtistDetailView: View {
    let artist: ArtistGroup

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel
    @State private var mode = ArtistPageMode.albums
    @State private var filter = FormatFilter.all

    private static let sortKey = "local.artist"

    private var tracks: [LibraryTrack] { artist.allTracks.filter(filter.matches) }
    private var albums: [AlbumGroup] { artist.albums.filter { filter.matches($0) } }
    private var guestTracks: [LibraryTrack] { artist.guestTracks.filter(filter.matches) }

    private var pendingReview: [LibraryTrack] {
        artist.allTracks.filter { model.index.unmatchedPaths.contains($0.path) }
    }

    private var folders: [String] {
        Array(Set(tracks.map(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                header
                HStack {
                    Picker("檢視方式", selection: $mode) {
                        ForEach(ArtistPageMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    FormatFilterMenu(filter: $filter)
                }
                content
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        DetailHeader(title: artist.name) {
            ArtworkView(source: .local(artist.albums[0].representative), side: Theme.coverSide, radius: Theme.coverSide / 2)
        } details: {
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(formatSummary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } actions: {
            actions
        }
    }

    private var summary: String {
        let all = artist.allTracks
        var parts = [String(localized: "\(artist.albums.count) 張專輯"), String(localized: "\(all.count) 首歌曲")]
        if !artist.guestTracks.isEmpty { parts.append(String(localized: "其中 \(artist.guestTracks.count) 首在其他專輯")) }
        parts.append(Format.longDuration(all.reduce(0) { $0 + $1.duration }))
        return parts.joined(separator: String(localized: "，"))
    }

    private var formatSummary: String {
        let all = artist.allTracks
        let hiRes = all.filter { FormatFilter(tiers: [.hiRes]).matches($0) }.count
        return String(localized: "Hi-Res \(hiRes) 首，CD 規格以下 \(all.count - hiRes) 首")
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            model.play(tracks: artist.allTracks)
        } label: {
            Label("播放", systemImage: "play.fill")
        }
        .buttonStyle(PrimaryPillStyle())
        .fixedSize()
        Button {
            model.play(tracks: artist.allTracks, shuffled: true)
        } label: {
            Label("隨機播放", systemImage: "shuffle")
        }
        .buttonStyle(SecondaryPillStyle())
        .fixedSize()
        MoreMenu {
            Button("下一首播放") { model.playNext(tracks: artist.allTracks) }
            Button("加入待播清單") { model.enqueue(tracks: artist.allTracks) }
            Divider()
            Button("輸出打包 \(albums.count) 張專輯…") {
                navigation.exportRequest = ExportSheetRequest(title: artist.name, albums: albums)
            }
            Button("在 Finder 中顯示所有資料夾") {
                let folders = Set(artist.allTracks.map(\.folder)).map { URL(fileURLWithPath: $0) }
                NSWorkspace.shared.activateFileViewerSelecting(folders)
            }
            if !pendingReview.isEmpty {
                Divider()
                Button("校閱 \(pendingReview.count) 首未匹配曲目") { navigation.review(pendingReview) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .albums:
            if albums.isEmpty && guestTracks.isEmpty {
                NoFormatMatches(filter: filter)
            }
            else {
                AlbumGrid(albums: albums)
                if !guestTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: String(localized: "其他專輯中的歌曲"))
                        LocalTrackList(tracks: guestTracks)
                    }
                }
            }
        case .tracks:
            if tracks.isEmpty { NoFormatMatches(filter: filter) }
            else { LocalTrackList(tracks: tracks, sortKey: Self.sortKey) }
        case .folders:
            if tracks.isEmpty {
                NoFormatMatches(filter: filter)
            }
            else {
                let tracks = self.tracks
                LazyVStack(spacing: 0) {
                    ForEach(folders, id: \.self) { folder in
                        ArtistFolderRow(folder: folder, tracks: tracks.filter { $0.folder == folder })
                    }
                }
            }
        }
    }
}

/// 一個資料夾一列，點一下到專輯頁
private struct ArtistFolderRow: View {
    let folder: String
    let tracks: [LibraryTrack]

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel
    @State private var isHovering = false

    private var pendingCount: Int {
        tracks.filter { model.index.unmatchedPaths.contains($0.path) }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: .local(tracks[0]), side: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(tracks[0].album)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(folder)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if pendingCount > 0 {
                Text("\(pendingCount) 首未匹配")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Text("\(tracks.count) 首")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在 Finder 中顯示")
            .accessibilityLabel("在 Finder 中顯示")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let album = model.index.albumsByPath[tracks[0].path] { navigation.open(.album(album)) }
        }
        .contextMenu { FolderPlaylistMenu(folder: folder) }
    }
}
