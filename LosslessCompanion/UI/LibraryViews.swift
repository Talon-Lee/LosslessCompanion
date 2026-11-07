//
//  LibraryViews.swift
//  LosslessCompanion
//

import SwiftUI

private let albumGridColumns = [GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 22, alignment: .top)]

struct AlbumCard: View {
    let album: AlbumGroup

    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false

    private static let side: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(source: .local(album.representative), side: Self.side, radius: Theme.artworkRadius)
                if isHovering {
                    Button {
                        model.play(tracks: album.tracks)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(9)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)

            Text(album.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            ArtistLink(name: album.artist)
        }
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { navigation.open(.album(album)) }
        .contextMenu {
            Button("下一首播放") { model.playNext(tracks: album.tracks) }
            Button("加入待播清單") { model.enqueue(tracks: album.tracks) }
            let pending = album.tracks.filter { model.index.unmatchedPaths.contains($0.path) }
            if !pending.isEmpty {
                Button("校閱 \(pending.count) 首未匹配曲目") { navigation.review(pending) }
            }
            Divider()
            AlbumFileActions(album: album)
        }
    }
}

struct PlaylistCard: View {
    let playlist: MusicPlaylist

    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var model: AppModel

    private static let side: CGFloat = 170

    var body: some View {
        let coverage = model.coverage(of: playlist)
        VStack(alignment: .leading, spacing: 6) {
            PlaylistCover(sources: model.coverSources(for: playlist), side: Self.side)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            Text(playlist.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Text(coverage.matched > 0 ? "本地 \(coverage.matched) / \(coverage.total) 首" : "\(coverage.total) 首歌曲")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { navigation.open(.playlist(playlist.id)) }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LocalLibrary

    private static let recentLimit = 14

    private var recentAlbums: [AlbumGroup] {
        Array(model.index.recent.prefix(Self.recentLimit))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageTitle(title: String(localized: "首頁"))

                HomeCoverage()

                if !playlists.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: String(localized: "你的 Apple Music 播放列表"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 22) {
                                ForEach(playlists.playlists) { PlaylistCard(playlist: $0) }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: String(localized: "最近加入的本地專輯"))
                    AlbumGrid(albums: recentAlbums)
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 全部曲目排第一，接著是自己的播放列表，由左往右。完全沒有本地檔案的不顯示
private struct HomeCoverage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playlists: PlaylistStore

    private var rings: [(id: String, title: String, coverage: PlaylistCoverage)] {
        let own = playlists.playlists.filter { !$0.isSubscription }
        let all = [(id: "all", title: String(localized: "全部曲目"), coverage: model.libraryCoverage)]
        return (all + own.map { (id: $0.id, title: $0.name, coverage: model.coverage(of: $0)) }).filter { $0.coverage.matched > 0 }
    }

    var body: some View {
        let rings = rings
        if !rings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: String(localized: "已配對曲目"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(rings, id: \.id) { ring in
                            VStack(spacing: 8) {
                                CoverageRing(coverage: ring.coverage, title: nil)
                                Text(ring.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                    .frame(width: CoverageRing.side)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AlbumsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var filter = FormatFilter.all

    var body: some View {
        let albums = settings.albumSort.sorted(model.albums.filter { filter.matches($0) })
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageHeader(title: String(localized: "專輯")) {
                    ExportPageButton(title: filter == .all ? String(localized: "全部專輯") : String(localized: "專輯 \(filter.title)"), albums: albums)
                    FormatFilterMenu(filter: $filter)
                    Menu {
                        Picker("排序方式", selection: $settings.albumSort) {
                            ForEach(AlbumSortKey.allCases) { key in
                                Text(key.title).tag(key)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        PageMenuLabel(title: settings.albumSort.title, systemImage: "arrow.up.arrow.down")
                    }
                    .pageMenuStyle()
                    .help("排序方式")
                    .accessibilityLabel("排序方式")
                }
                if albums.isEmpty && filter != .all {
                    NoFormatMatches(filter: filter)
                }
                else if settings.albumSort == .sampleRate {
                    AlbumRateSections(albums: albums)
                }
                else {
                    AlbumGrid(albums: albums)
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 依取樣率分段顯示專輯
struct AlbumRateSections: View {
    let albums: [AlbumGroup]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(LibraryBrowser.rateGroups(from: albums)) { group in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SectionHeading(title: group.title)
                        Text("\(group.albums.count) 張")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    AlbumGrid(albums: group.albums)
                }
            }
        }
    }
}

/// 選項取自音樂庫裡實際有的規格，不列出用不到的。
/// 選單點一下就會關上，複選要連續勾好幾項，所以用浮動視窗
struct FormatFilterMenu: View {
    @Binding var filter: FormatFilter

    @EnvironmentObject private var library: LocalLibrary
    @State private var showsOptions = false

    private static let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    private var label: String {
        switch filter.titles.count {
        case 0: return String(localized: "全部規格")
        case 1: return filter.title
        default: return String(localized: "已選 \(filter.titles.count) 項規格")
        }
    }

    var body: some View {
        Button {
            showsOptions.toggle()
        } label: {
            PageMenuLabel(title: label, systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(filter == .all ? String(localized: "依規格篩選") : filter.title)
        .accessibilityLabel("依規格篩選")
        .popover(isPresented: $showsOptions, arrowEdge: .bottom) { options }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("依規格篩選")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("清除") { filter = .all }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(filter == .all)
            }
            section("等級", FormatFilter.Tier.allCases, in: \.tiers) { $0.title }
            section("取樣率", Set(library.tracks.map(\.sampleRate)).sorted(), in: \.sampleRates) { Format.sampleRate($0) }
            section("位元深度", Set(library.tracks.map(\.bitsPerSample)).sorted(), in: \.bitDepths, title: FormatFilter.title(bits:))
            section("檔案類型", Set(library.tracks.map(FormatFilter.fileType)).sorted(), in: \.fileTypes) { $0 }
        }
        .padding(14)
        .frame(width: 270)
    }

    private func section<Value: Hashable>(_ heading: LocalizedStringKey, _ values: [Value],
                                          in selection: WritableKeyPath<FormatFilter, Set<Value>>,
                                          title: @escaping (Value) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Toggle(title(value), isOn: isSelected(value, in: selection))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func isSelected<Value: Hashable>(_ value: Value, in selection: WritableKeyPath<FormatFilter, Set<Value>>) -> Binding<Bool> {
        Binding {
            filter[keyPath: selection].contains(value)
        } set: { isOn in
            if isOn { filter[keyPath: selection].insert(value) }
            else { filter[keyPath: selection].remove(value) }
        }
    }
}

struct NoFormatMatches: View {
    let filter: FormatFilter

    var body: some View {
        ContentUnavailableView("沒有符合「\(filter.title)」的檔案", systemImage: "line.3.horizontal.decrease")
            .frame(maxWidth: .infinity)
    }
}

struct AlbumGrid: View {
    let albums: [AlbumGroup]

    var body: some View {
        LazyVGrid(columns: albumGridColumns, alignment: .leading, spacing: 24) {
            ForEach(albums) { AlbumCard(album: $0) }
        }
    }
}

/// 歌手、類型、作曲者點進去都是一組專輯
struct AlbumCollectionView: View {
    let title: String
    let albums: [AlbumGroup]

    @EnvironmentObject private var model: AppModel

    private var tracks: [LibraryTrack] { albums.flatMap(\.tracks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageHeader(title: title) {
                    ExportPageButton(title: title, albums: albums)
                }
                HStack(spacing: 10) {
                    Button {
                        model.play(tracks: tracks)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    Button {
                        model.play(tracks: tracks, shuffled: true)
                    } label: {
                        Label("隨機播放", systemImage: "shuffle")
                    }
                    .buttonStyle(SecondaryPillStyle())
                    .fixedSize()
                    Text("\(albums.count) 張專輯，\(tracks.count) 首歌曲")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                AlbumGrid(albums: albums)
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecentlyAddedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageHeader(title: String(localized: "最近加入")) {
                    ExportPageButton(title: String(localized: "最近加入"), albums: model.index.recent)
                }
                AlbumGrid(albums: model.index.recent)
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Music 資料庫最近加入的專輯，串流歌曲也在內；有本地檔案的播放時走獨佔
struct MusicRecentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageTitle(title: String(localized: "Apple Music 最近加入"))
                if model.index.recentMusic.isEmpty {
                    ContentUnavailableView("還沒有同步 Apple Music 資料庫", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                else {
                    LazyVGrid(columns: albumGridColumns, alignment: .leading, spacing: 24) {
                        ForEach(model.index.recentMusic) { MusicAlbumCard(album: $0) }
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MusicAlbumCard: View {
    let album: MusicAlbum

    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false

    private static let side: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(source: model.coverSources(for: album.playlist, limit: 1).first ?? .none,
                            side: Self.side, radius: Theme.artworkRadius)
                if isHovering {
                    Button {
                        model.play(album.playlist)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(9)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)

            Text(album.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Text(album.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { navigation.open(.musicAlbum(album)) }
        .contextMenu {
            Button("下一首播放") { model.playNext(album.playlist.entries, in: album.playlist) }
            Button("加入待播清單") { model.enqueue(album.playlist.entries, in: album.playlist) }
            if let local = album.playlist.entries.lazy.compactMap({ model.localAlbum(for: $0) }).first {
                Divider()
                Button("前往本地專輯") { navigation.open(.album(local)) }
            }
        }
    }
}

struct CompilationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageHeader(title: String(localized: "合輯")) {
                    ExportPageButton(title: String(localized: "合輯"), albums: model.index.compilations)
                }
                if model.index.compilations.isEmpty {
                    ContentUnavailableView("沒有合輯", systemImage: "person.2")
                        .frame(maxWidth: .infinity)
                }
                else {
                    AlbumGrid(albums: model.index.compilations)
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GroupRow: View {
    let artwork: ArtworkSource
    let title: String
    let subtitle: String
    let index: Int
    var artworkRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: artwork, side: 40, radius: artworkRadius)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
        }
        .contentShape(Rectangle())
    }
}

/// 類型與作曲者清單
struct CategoryListView: View {
    let title: String
    let groups: [CategoryGroup]
    let emptyMessage: String

    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageTitle(title: title)
                if groups.isEmpty {
                    ContentUnavailableView(emptyMessage, systemImage: "music.note.list")
                        .frame(maxWidth: .infinity)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        Button {
                            navigation.open(.category(group))
                        } label: {
                            GroupRow(artwork: .local(group.albums[0].representative), title: group.name,
                                     subtitle: String(localized: "\(group.albums.count) 張專輯，\(group.trackCount) 首歌曲"), index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GenresView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        CategoryListView(title: String(localized: "類型"), groups: model.index.genres, emptyMessage: String(localized: "沒有類型資料"))
    }
}

struct ComposersView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        CategoryListView(title: String(localized: "作曲者"), groups: model.index.composers, emptyMessage: String(localized: "沒有作曲者資料"))
    }
}

/// 在 Music 資料庫裡找不到對應歌曲的本地檔案，可以在這裡手動校閱
struct UnmatchedView: View {
    private enum Mode: CaseIterable, Identifiable {
        case albums
        case tracks
        case duplicates
        case reviewed

        var id: Self { self }

        var title: String {
            switch self {
            case .albums: return String(localized: "專輯")
            case .tracks: return String(localized: "曲目")
            case .duplicates: return String(localized: "重複檔案")
            case .reviewed: return String(localized: "已校閱")
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var navigation: NavigationModel
    @State private var mode = Mode.albums

    private var tracks: [LibraryTrack] { model.index.unmatchedTracks }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageTitle(title: String(localized: "未匹配曲目／專輯"))
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Picker("檢視方式", selection: $mode) {
                        ForEach(Mode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    if mode == .albums {
                        ExportPageButton(title: String(localized: "未匹配專輯"), albums: model.index.unmatchedAlbums)
                    }
                    Button {
                        navigation.review(model.reviewQueue)
                    } label: {
                        Label("開始校閱", systemImage: "checklist")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    .disabled(model.reviewQueue.isEmpty || playlists.library.isEmpty)
                }

                switch mode {
                case .albums:
                    AlbumGrid(albums: AlbumSortKey.title.sorted(model.index.unmatchedAlbums))
                case .tracks:
                    LocalTrackList(tracks: tracks, sortKey: Self.sortKey)
                case .duplicates:
                    DuplicateList()
                case .reviewed:
                    ReviewedList()
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let sortKey = "local.unmatched"

    private var summary: String {
        if playlists.library.isEmpty { return String(localized: "同步 Apple Music 資料庫後才能比對。請開啟 Apple Music。") }
        let suggested = model.reviewScores.keys.filter { model.duplicates[$0] == nil }.count
        var parts = [String(localized: "\(tracks.count) 首、\(model.index.unmatchedAlbums.count) 張專輯在 Apple Music 資料庫裡找不到相同的歌曲")]
        if suggested > 0 { parts.append(String(localized: "\(suggested) 首有相近的候選")) }
        if !model.duplicates.isEmpty { parts.append(String(localized: "\(model.duplicates.count) 首是重複檔案")) }
        return parts.joined(separator: String(localized: "，")) + String(localized: "。")
    }
}

/// 同一首歌的另一份檔案。Apple Music 歌單只會用已配對的那一份，這裡的檔案仍然可以直接播放
struct DuplicateList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel

    private var tracks: [LibraryTrack] {
        model.index.unmatchedTracks.filter { model.duplicates[$0.path] != nil }
    }

    var body: some View {
        if tracks.isEmpty {
            ContentUnavailableView("沒有重複檔案", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("歌單已經使用另一份檔案。要改用這一份，請按「校閱」。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全部標記為僅本地") { model.review.markLocalOnly(tracks) }
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        if let kept = model.duplicates[track.path] {
                            DuplicateRow(track: track, kept: kept, index: index)
                        }
                    }
                }
            }
        }
    }
}

private struct DuplicateRow: View {
    let track: LibraryTrack
    let kept: LibraryTrack
    let index: Int

    @EnvironmentObject private var navigation: NavigationModel

    private func spec(_ track: LibraryTrack) -> String {
        Format.quality(rate: track.sampleRate, bits: track.bitsPerSample)
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: .local(track), side: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(track.title)（\(spec(track))）")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("使用中：\(kept.url.lastPathComponent)（\(spec(kept))）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在 Finder 中顯示")
            .accessibilityLabel("在 Finder 中顯示")
            Button("校閱") { navigation.review([track]) }
                .controlSize(.small)
        }
        .padding(.horizontal, TrackColumns.horizontalPadding)
        .frame(height: Theme.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
        }
    }
}

/// 手動連結與標記為僅本地的曲目，每一筆都可以復原
private struct ReviewedList: View {
    @EnvironmentObject private var model: AppModel

    private var tracks: [LibraryTrack] { model.index.linkedTracks + model.index.localOnlyTracks }

    var body: some View {
        if tracks.isEmpty {
            ContentUnavailableView("還沒有校閱過的曲目", systemImage: "checklist")
                .frame(maxWidth: .infinity)
        }
        else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    ReviewedRow(track: track, index: index)
                }
            }
        }
    }
}

private struct ReviewedRow: View {
    let track: LibraryTrack
    let index: Int

    @EnvironmentObject private var model: AppModel

    private var detail: String {
        if case .linked(let link) = model.reviewStatus(of: track) {
            return String(localized: "已連結到 \(link.title) — \(link.artist)")
        }
        return String(localized: "僅本地")
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: .local(track), side: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("復原") { model.review.undo(track.path) }
                .controlSize(.small)
        }
        .padding(.horizontal, TrackColumns.horizontalPadding)
        .frame(height: Theme.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
        }
    }
}

struct AlbumDetailView: View {
    let album: AlbumGroup

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel

    private var pendingReview: [LibraryTrack] {
        album.tracks.filter { model.index.unmatchedPaths.contains($0.path) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                DetailHeader(title: album.title) {
                    ArtworkView(source: .local(album.representative), side: Theme.coverSide, radius: Theme.artworkRadius)
                } details: {
                    ArtistLink(name: album.artist, font: .system(size: 15, weight: .medium))
                    Text("\(album.tracks.count) 首歌曲，\(Format.longDuration(album.totalDuration))，\(Format.sampleRates(album.sampleRates)) / \(album.bestFormat.bits)-bit")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } actions: {
                    Button {
                        model.play(tracks: album.tracks)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    Button {
                        model.play(tracks: album.tracks, shuffled: true)
                    } label: {
                        Label("隨機播放", systemImage: "shuffle")
                    }
                    .buttonStyle(SecondaryPillStyle())
                    .fixedSize()
                    MoreMenu {
                        Button("下一首播放") { model.playNext(tracks: album.tracks) }
                        Button("加入待播清單") { model.enqueue(tracks: album.tracks) }
                        if !pendingReview.isEmpty {
                            Button("校閱 \(pendingReview.count) 首未匹配曲目") { navigation.review(pendingReview) }
                        }
                        Divider()
                        AlbumFileActions(album: album)
                        Button("在 Finder 中顯示") {
                            NSWorkspace.shared.activateFileViewerSelecting(Array(Set(album.tracks.map(\.folder))).map { URL(fileURLWithPath: $0) })
                        }
                    }
                }

                LocalTrackList(tracks: album.tracks)
            }
            .padding(Theme.pagePadding)
        }
        .background(alignment: .top) {
            ArtworkBackdrop(source: .local(album.representative))
        }
    }
}

struct ArtistsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageTitle(title: String(localized: "歌手"))
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.artists.enumerated()), id: \.element.id) { index, artist in
                        Button {
                            navigation.open(.artist(artist))
                        } label: {
                            GroupRow(artwork: .local(artist.albums[0].representative), title: artist.name,
                                     subtitle: String(localized: "\(artist.albums.count) 張專輯，\(artist.trackCount) 首歌曲"), index: index, artworkRadius: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SongsView: View {
    @EnvironmentObject private var library: LocalLibrary
    @State private var filter = FormatFilter.all

    private static let sortKey = "local.songs"

    var body: some View {
        let tracks = library.tracks.filter { filter.matches($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageHeader(title: String(localized: "歌曲")) {
                    FormatFilterMenu(filter: $filter)
                }
                if tracks.isEmpty && filter != .all {
                    NoFormatMatches(filter: filter)
                }
                else {
                    LocalTrackList(tracks: tracks, sortKey: Self.sortKey)
                }
            }
            .padding(Theme.pagePadding)
        }
    }
}

/// 本地歌曲列表；雙擊或點封面從該首開始播放整份清單。傳入 sortKey 才能排序
struct LocalTrackList: View {
    let tracks: [LibraryTrack]
    var sortKey: String?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var playCounts: PlayCountStore

    private var sort: Binding<TrackSort>? {
        sortKey.map { key in
            Binding(get: { settings.trackSort(for: key) }, set: { settings.setTrackSort($0, for: key) })
        }
    }

    var body: some View {
        let ordered = sort.map { model.sortedTracks(tracks, by: $0.wrappedValue) } ?? tracks
        TrackListView(rows: rows(ordered), sort: sort, sortKeys: TrackSortKey.localSelectable) { row in
            model.play(tracks: ordered, from: ordered[row.index])
        } menu: { row in
            Button("播放") { model.play(tracks: ordered, from: ordered[row.index]) }
            Button("下一首播放") { model.playNext(tracks: [ordered[row.index]]) }
            Button("加入待播清單") { model.enqueue(tracks: [ordered[row.index]]) }
            Divider()
            Button("整理檔案…") {
                let track = ordered[row.index]
                navigation.organizeRequest = OrganizeSheetRequest(title: track.title, tracks: [track])
            }
            Button("在 Finder 中顯示") {
                NSWorkspace.shared.activateFileViewerSelecting([ordered[row.index].url])
            }
            reviewItems(for: ordered[row.index])
        }
    }

    @ViewBuilder
    private func reviewItems(for track: LibraryTrack) -> some View {
        switch model.reviewStatus(of: track) {
        case .automatic:
            EmptyView()
        case .unmatched:
            Divider()
            Button("校閱配對…") { navigation.review([track]) }
            Button("標記為僅本地") { model.review.markLocalOnly(track) }
        case .linked, .localOnly:
            Divider()
            Button("復原校閱") { model.review.undo(track.path) }
        }
    }

    private func rows(_ tracks: [LibraryTrack]) -> [TrackRowModel] {
        tracks.enumerated().map { index, track in
            TrackRowModel(id: track.path, index: index, title: track.title, artist: track.artist, album: track.album,
                          duration: track.duration, artwork: .local(track),
                          quality: (track.sampleRate, track.bitsPerSample), isStreamOnly: false, isDimmed: false,
                          isFavorite: model.favoritePaths.contains(track.path),
                          playCount: playCounts.count(for: track.path))
        }
    }
}

struct SearchResultsView: View {
    let query: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var navigation: NavigationModel

    private static let songLimit = 24

    private var tokens: [String] { SearchText.tokens(of: query) }

    private var matchingPlaylists: [MusicPlaylist] {
        playlists.playlists.filter { playlist in
            let name = SearchText.normalize(playlist.name)
            return tokens.allSatisfy(name.contains)
        }
    }

    private var matchingAlbums: [AlbumGroup] {
        Array(model.albums.filter { album in
            let key = SearchText.normalize(album.title + "\n" + album.artist)
            return tokens.allSatisfy(key.contains)
        }.prefix(12))
    }

    /// 只有歌單裡才有的串流歌曲；已有本地檔案的不重複列出
    private var streamMatches: [(playlist: MusicPlaylist, entry: MusicPlaylistEntry)] {
        var seen = Set<String>()
        var results = [(MusicPlaylist, MusicPlaylistEntry)]()
        for playlist in playlists.playlists {
            for entry in playlist.entries where model.match(for: entry) == nil {
                let key = SearchText.normalize(entry.title + "\n" + entry.artist + "\n" + entry.album)
                guard tokens.allSatisfy(key.contains), seen.insert(entry.trackID).inserted else { continue }
                results.append((playlist, entry))
                if results.count == Self.songLimit { return results }
            }
        }
        return results
    }

    var body: some View {
        let localTracks = library.search(query, limit: Self.songLimit)
        let streamResults = streamMatches
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageTitle(title: String(localized: "搜尋結果"))

                if !matchingPlaylists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: String(localized: "播放列表"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 22) {
                                ForEach(matchingPlaylists) { PlaylistCard(playlist: $0) }
                            }
                        }
                    }
                }

                if !matchingAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: String(localized: "本地專輯"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 22) {
                                ForEach(matchingAlbums) { AlbumCard(album: $0) }
                            }
                        }
                    }
                }

                if !localTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: String(localized: "本地歌曲"))
                        LocalTrackList(tracks: localTracks)
                    }
                }

                if !streamResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: String(localized: "Apple Music 播放列表中的歌曲"))
                        TrackListView(rows: streamRows(streamResults)) { row in
                            let result = streamResults[row.index]
                            model.play(result.playlist, from: result.entry, forcedRoute: .appleMusic)
                        } menu: { row in
                            streamMenu(streamResults[row.index])
                        }
                    }
                }

                if matchingPlaylists.isEmpty, matchingAlbums.isEmpty, localTracks.isEmpty, streamResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func streamMenu(_ result: (playlist: MusicPlaylist, entry: MusicPlaylistEntry)) -> some View {
        let entry = result.entry
        Button("以 Apple Music 播放") {
            model.play(result.playlist, from: entry, forcedRoute: .appleMusic)
        }
        Button("下一首播放") { model.playNext([entry], in: result.playlist) }
        Button("加入待播清單") { model.enqueue([entry], in: result.playlist) }
        Divider()
        if let album = model.musicAlbum(forTrackID: entry.trackID) {
            Button("前往 Apple Music 專輯") { navigation.open(.musicAlbum(album)) }
        }
        // 同一首歌可能在好幾張播放列表裡，讓使用者選要看哪一張
        let containing = model.playlists(containing: entry.trackID)
        if containing.count > 1 {
            Menu("在播放列表中顯示") {
                ForEach(containing) { playlist in
                    Button(playlist.name) { navigation.reveal(trackID: entry.trackID, in: playlist.id) }
                }
            }
        }
        else {
            Button("在「\(result.playlist.name)」中顯示") {
                navigation.reveal(trackID: entry.trackID, in: result.playlist.id)
            }
        }
    }

    private func streamRows(_ results: [(playlist: MusicPlaylist, entry: MusicPlaylistEntry)]) -> [TrackRowModel] {
        results.enumerated().map { index, result in
            TrackRowModel(id: "\(result.playlist.id)-\(result.entry.id)", index: index,
                          title: result.entry.title, artist: result.entry.artist, album: result.entry.album,
                          duration: result.entry.duration,
                          artwork: .stream(StreamReference(playlistID: result.playlist.id, trackID: result.entry.trackID)),
                          quality: nil, isStreamOnly: true, isDimmed: false,
                          isFavorite: result.entry.isFavorite == true)
        }
    }
}
