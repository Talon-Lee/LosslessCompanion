//
//  PlaylistDetailView.swift
//  LosslessCompanion
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: MusicPlaylist
    /// Music 資料庫的專輯也用這一頁，標題上方改顯示歌手
    var albumArtist: String?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: NavigationModel
    @State private var query = ""
    @State private var highlightedID: String?

    /// 從搜尋跳過來時標出那首歌的時間
    private static let highlightTime: TimeInterval = 2.5

    private var preference: RoutePreference {
        settings.preference(for: playlist.id)
    }

    private var sort: Binding<TrackSort> {
        Binding(get: { settings.trackSort(for: playlist.id) },
                set: { settings.setTrackSort($0, for: playlist.id) })
    }

    var body: some View {
        let entries = filtered(model.sortedEntries(of: playlist))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                    header
                    if albumArtist == nil {
                        PlaylistSearchField(text: $query)
                    }
                    if entries.isEmpty, !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                    }
                    else {
                        TrackListView(rows: rows(entries), sort: sort,
                                      originalSortTitle: albumArtist == nil ? String(localized: "播放列表順序") : String(localized: "專輯順序"),
                                      highlightedID: highlightedID) { row in
                            play(entries[row.index])
                        } menu: { row in
                            rowMenu(entries[row.index])
                        }
                    }
                }
                .padding(Theme.pagePadding)
            }
            .onAppear { reveal(proxy) }
            .onChange(of: navigation.revealRequest) { reveal(proxy) }
        }
        .background(alignment: .top) {
            ArtworkBackdrop(source: model.coverSources(for: playlist, limit: 1).first ?? .none)
        }
    }

    private func filtered(_ entries: [MusicPlaylistEntry]) -> [MusicPlaylistEntry] {
        let tokens = SearchText.tokens(of: query)
        guard !tokens.isEmpty else { return entries }
        return entries.filter { entry in
            let key = model.searchKey(for: entry)
            return tokens.allSatisfy(key.contains)
        }
    }

    private func rowID(_ entry: MusicPlaylistEntry) -> String {
        "\(playlist.id)-\(entry.id)"
    }

    /// 捲到要找的歌並標出來一下。頁面剛建立時列表還沒排好，晚一點才捲得到
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let request = navigation.revealRequest, request.playlistID == playlist.id, albumArtist == nil,
              let entry = playlist.entries.first(where: { $0.trackID == request.trackID }) else { return }
        navigation.revealRequest = nil
        query = ""
        let id = rowID(entry)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            highlightedID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightTime) {
                if highlightedID == id { withAnimation(.easeOut(duration: 0.4)) { highlightedID = nil } }
            }
        }
    }

    private var header: some View {
        let coverage = model.coverage(of: playlist)
        return DetailHeader(title: playlist.name) {
            PlaylistCover(sources: model.coverSources(for: playlist), side: Theme.coverSide)
        } details: {
            Text(albumArtist ?? (playlist.isSubscription ? String(localized: "Apple Music 精選") : String(localized: "Apple Music 播放列表")))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(playlist.entries.count) 首歌曲，\(Format.longDuration(playlist.totalDuration))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } actions: {
            Button {
                model.play(playlist)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryPillStyle())
            .fixedSize()

            Button {
                model.play(playlist, shuffled: true)
            } label: {
                Label("隨機播放", systemImage: "shuffle")
            }
            .buttonStyle(SecondaryPillStyle())
            .fixedSize()

            routePicker
                .padding(.leading, 4)
        } accessory: {
            if coverage.matched > 0 { CoverageRing(coverage: coverage) }
        }
    }

    private var routePicker: some View {
        Picker("播放來源", selection: Binding(get: { preference }, set: { settings.setPreference($0, for: playlist.id) })) {
            ForEach(RoutePreference.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func rows(_ entries: [MusicPlaylistEntry]) -> [TrackRowModel] {
        entries.enumerated().map { index, entry in
            let match = model.match(for: entry)
            return TrackRowModel(id: rowID(entry),
                                 index: index,
                                 title: entry.title,
                                 artist: entry.artist,
                                 album: entry.album,
                                 duration: entry.duration,
                                 artwork: model.artworkSource(for: entry, in: playlist),
                                 quality: preference == .appleMusicOnly ? nil : match.map { ($0.track.sampleRate, $0.track.bitsPerSample) },
                                 isStreamOnly: match == nil,
                                 isDimmed: !isPlayable(entry, match: match),
                                 isFavorite: entry.isFavorite == true)
        }
    }

    private func isPlayable(_ entry: MusicPlaylistEntry, match: LocalMatch?) -> Bool {
        switch preference {
        case .preferLocal: return match != nil || entry.isStreamable
        case .localOnly: return match != nil
        case .appleMusicOnly: return entry.isStreamable
        }
    }

    private func play(_ entry: MusicPlaylistEntry) {
        guard isPlayable(entry, match: model.match(for: entry)) else { return }
        model.play(playlist, from: entry)
    }

    @ViewBuilder
    private func rowMenu(_ entry: MusicPlaylistEntry) -> some View {
        if model.match(for: entry) != nil {
            Button("以本地獨佔播放") { model.play(playlist, from: entry, forcedRoute: .local) }
        }
        if entry.isStreamable {
            Button("以 Apple Music 播放") { model.play(playlist, from: entry, forcedRoute: .appleMusic) }
        }
        if isPlayable(entry, match: model.match(for: entry)) {
            Button("下一首播放") { model.playNext([entry], in: playlist) }
            Button("加入待播清單") { model.enqueue([entry], in: playlist) }
        }
        let localAlbum = model.localAlbum(for: entry)
        // 已經在這張專輯頁就不用再列
        let musicAlbum = albumArtist == nil ? model.musicAlbum(forTrackID: entry.trackID) : nil
        if localAlbum != nil || musicAlbum != nil { Divider() }
        if let localAlbum {
            Button("前往本地專輯") { navigation.open(.album(localAlbum)) }
        }
        if let musicAlbum {
            Button("前往 Apple Music 專輯") { navigation.open(.musicAlbum(musicAlbum)) }
        }
    }
}

/// 只篩選這張播放列表裡的歌
struct PlaylistSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("在播放列表中搜尋", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 260, height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 歌單裡有幾首能用本地無損播放。進入頁面時從 0% 長到實際比例
struct CoverageRing: View {
    let coverage: PlaylistCoverage
    /// 圓心最上面的字；首頁把名稱放在圓環下方，這裡就不用
    var title: String? = String(localized: "本地無損")

    @Environment(\.isPageOnTop) private var isPageOnTop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0

    static let side: CGFloat = 96
    private static let lineWidth: CGFloat = 6
    private static let fillDuration: TimeInterval = 0.9

    private func fill() {
        guard !reduceMotion else {
            shown = coverage.fraction
            return
        }
        withAnimation(.easeOut(duration: Self.fillDuration)) { shown = coverage.fraction }
    }

    var body: some View {
        ZStack {
            // 線寬一半會超出外框，首頁放在捲動區裡會被裁掉，所以往內縮
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(Color.primary.opacity(0.1), lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: shown)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                if let title {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                CoveragePercent(fraction: shown)
                Text("\(coverage.matched.formatted()) / \(coverage.total.formatted())")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, Self.lineWidth + 4)
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title ?? String(localized: "已配對")) \(coverage.matched) 首，共 \(coverage.total) 首")
        .onAppear { if isPageOnTop { fill() } }
        // 比對完成或歌單更新時接著往上長
        .onChange(of: coverage.fraction) { fill() }
        // 底下的頁面一直留著，onAppear 不會再跑一次。離開時先歸零，回來才看得到動畫
        .onChange(of: isPageOnTop) { _, isOnTop in
            if isOnTop { fill() }
            else { shown = 0 }
        }
    }
}

/// 動畫的每一格都要重算文字，所以把數值做成可以內插的
private struct CoveragePercent: View, Animatable {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Text("\(PlaylistCoverage.percent(fraction))%")
            .font(.system(size: 16, weight: .semibold))
            .monospacedDigit()
    }
}

/// 頁首用封面顏色淡出到視窗背景。放大極小的縮圖就有柔和的色塊，不必另外模糊
struct ArtworkBackdrop: View {
    let source: ArtworkSource

    @ObservedObject private var store = ArtworkStore.shared
    @State private var image: NSImage?

    private static let thumbnailSide: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .saturation(0.9)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(0.22)
                    .mask {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    }
            }
        }
        .frame(height: 400)
        .allowsHitTesting(false)
        .task(id: ArtworkRequest(source: source, generation: store.generation)) {
            image = await store.image(for: source, side: Self.thumbnailSide)
        }
    }
}
