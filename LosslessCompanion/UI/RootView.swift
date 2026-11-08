//
//  RootView.swift
//  LosslessCompanion
//

import SwiftUI

enum SidebarItem: Hashable {
    case home
    case recentlyAdded
    case artists
    case albums
    case songs
    case genres
    case composers
    case compilations
    case unmatched
    case inbox
    case musicRecent
    case folderPlaylist(String)
    case playlist(String)
    case settings
}

enum Destination: Hashable {
    case album(AlbumGroup)
    case artist(ArtistGroup)
    case category(CategoryGroup)
    case musicAlbum(MusicAlbum)
}

extension EnvironmentValues {
    /// 子頁面疊在上面時，底下的頁面只是隱藏，回到它時不會重新出現
    @Entry var isPageOnTop = true
}

struct PlaylistReveal: Equatable {
    let playlistID: String
    let trackID: String
}

final class NavigationModel: ObservableObject {
    @Published var selection: SidebarItem? = .home
    @Published var path = [Destination]()
    @Published var showsQueue = false
    @Published var reviewRequest: MatchReviewRequest?
    @Published var organizeRequest: OrganizeSheetRequest?
    @Published var mergeRequest: AlbumMergeSheetRequest?
    @Published var exportRequest: ExportSheetRequest?
    @Published var showsPlayer = false
    @Published var revealRequest: PlaylistReveal?
    @Published var searchText = "" {
        didSet { if !searchText.isEmpty { path = [] } }
    }

    func open(_ item: SidebarItem) {
        selection = item
        path = []
        searchText = ""
    }

    func open(_ destination: Destination) {
        searchText = ""
        // 歌手頁裡的專輯卡片也有歌手連結，已經在這一頁就不用再疊一層
        if path.last != destination { path.append(destination) }
    }

    /// 打開播放列表並捲到這首歌
    func reveal(trackID: String, in playlistID: String) {
        open(.playlist(playlistID))
        revealRequest = PlaylistReveal(playlistID: playlistID, trackID: trackID)
    }

    func review(_ tracks: [LibraryTrack]) {
        guard !tracks.isEmpty else { return }
        reviewRequest = MatchReviewRequest(tracks: tracks)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var navigation = AppModel.shared.navigation
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    /// 開啟時先顯示標誌。預覽與測試不顯示，LC_PREVIEW_SPLASH 可以強制顯示來截圖
    @State private var showsSplash = AppRuntime.current.isLive || ProcessInfo.processInfo.environment["LC_PREVIEW_SPLASH"] != nil
    private static let splashDuration: TimeInterval = 1.6

    /// 側欄收起時，視窗按鈕與側欄按鈕會落在播放列左邊
    private static let windowButtonsInset: CGFloat = 130

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        } detail: {
            VStack(spacing: 0) {
                NowPlayingBar(showsQueue: $navigation.showsQueue,
                              leadingInset: sidebarVisibility == .detailOnly ? Self.windowButtonsInset : 0)
                Divider()
                StallBanner()
                OrganizeBanner()
                PageStack()
                    // 頁面再窄也不能撐開視窗：撐開時側欄和待播清單會一起被推出視窗外
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipped()
                    .inspector(isPresented: $navigation.showsQueue) {
                        QueueView()
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
                    }
            }
            // 標題列的高度會被保留，播放列要貼齊視窗頂端
            .ignoresSafeArea(.container, edges: .top)
        }
        .sheet(item: $navigation.reviewRequest) { MatchReviewSheet(request: $0) }
        .sheet(item: $navigation.organizeRequest) { OrganizeSheet(request: $0) }
        .sheet(item: $navigation.mergeRequest) { AlbumMergeSheet(request: $0) }
        .sheet(item: $navigation.exportRequest) { ExportSheet(request: $0) }
        .overlay {
            // 蓋住整個視窗：另開視窗在全螢幕時會跳到別的桌面
            if navigation.showsPlayer {
                PlayerPage()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: navigation.showsPlayer)
        .overlay {
            if showsSplash {
                LaunchSplash()
                    .transition(.opacity)
                    .onTapGesture { showsSplash = false }
            }
        }
        .animation(.easeOut(duration: 0.45), value: showsSplash)
        .task {
            guard showsSplash, ProcessInfo.processInfo.environment["LC_PREVIEW_SPLASH"] == nil else { return }
            try? await Task.sleep(for: .seconds(Self.splashDuration))
            showsSplash = false
        }
        .environmentObject(navigation)
        .frame(minWidth: 1040, minHeight: 640)
    }
}

/// 子頁面疊在主頁上，只顯示最上面一層，底下的頁面留著才能保留捲動位置。
/// 不用 NavigationStack：推入頁面時它會把同一欄的播放列一起換掉，工具列還會多一個返回鍵
struct PageStack: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        ZStack {
            layer(isTop: navigation.path.isEmpty) { MainPage() }
            ForEach(Array(navigation.path.enumerated()), id: \.offset) { index, destination in
                layer(isTop: index == navigation.path.count - 1) { DestinationPage(destination: destination) }
            }
        }
    }

    private func layer<Content: View>(isTop: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .environment(\.isPageOnTop, isTop)
            .opacity(isTop ? 1 : 0)
            .allowsHitTesting(isTop)
            .accessibilityHidden(!isTop)
    }
}

/// 子頁面沒有系統的返回鍵，自己放一個
struct BackButton: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        Button {
            if !navigation.path.isEmpty { navigation.path.removeLast() }
        } label: {
            Label("返回", systemImage: "chevron.left")
                .font(.system(size: 12.5, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut("[", modifiers: .command)
    }
}

struct StallBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isMusicStalled {
            HStack(spacing: 10) {
                Image(systemName: "speaker.slash.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Apple Music 沒有聲音").font(.system(size: 13, weight: .semibold))
                    Text("自動重新開啟之後還是卡住。可以再手動重開一次，Music 自己的播放佇列會被清空。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("稍後") { model.dismissStall() }
                Button("重新開啟 Apple Music") { model.restartMusic() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(12)
            .background(Color.primary.opacity(0.05))
        }
    }
}

struct MainPage: View {
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var folderPlaylists: FolderPlaylistStore

    var body: some View {
        if !navigation.searchText.isEmpty {
            SearchResultsView(query: navigation.searchText)
        }
        else {
            switch navigation.selection ?? .home {
            case .home: HomeView()
            case .recentlyAdded: RecentlyAddedView()
            case .artists: ArtistsView()
            case .albums: AlbumsView()
            case .songs: SongsView()
            case .genres: GenresView()
            case .composers: ComposersView()
            case .compilations: CompilationsView()
            case .unmatched: UnmatchedView()
            case .inbox: InboxView()
            case .musicRecent: MusicRecentView()
            case .folderPlaylist(let id):
                if let playlist = folderPlaylists.playlist(id: id) {
                    FolderPlaylistView(playlist: playlist).id(id)
                }
                else {
                    ContentUnavailableView("找不到這張播放列表", systemImage: "folder")
                }
            case .playlist(let id):
                if let playlist = playlists.playlist(id: id) {
                    PlaylistDetailView(playlist: playlist).id(id)
                }
                else {
                    ContentUnavailableView("找不到這張播放列表", systemImage: "music.note.list")
                }
            case .settings: SettingsView()
            }
        }
    }
}

struct DestinationPage: View {
    let destination: Destination

    @EnvironmentObject private var model: AppModel

    /// 開著的頁面要跟著索引更新，改名與合併之後才不會還拿著舊路徑
    private func current(_ category: CategoryGroup) -> CategoryGroup {
        (model.index.genres + model.index.composers).first { $0.id == category.id } ?? category
    }

    var body: some View {
        Group {
            switch destination {
            case .album(let album): AlbumDetailView(album: model.index.albumsByID[album.id] ?? album)
            case .artist(let artist): ArtistDetailView(artist: model.index.artistsByName[artist.name] ?? artist)
            case .category(let category):
                let category = current(category)
                AlbumCollectionView(title: category.name, albums: category.albums)
            case .musicAlbum(let album): PlaylistDetailView(playlist: album.playlist, albumArtist: album.artist)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                BackButton()
                Spacer()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 8)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var folderPlaylists: FolderPlaylistStore
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var inbox: InboxModel

    var body: some View {
        List(selection: selectionBinding) {
            Label("首頁", systemImage: "house")
                .tag(SidebarItem.home)

            Section {
                Label("最近加入", systemImage: "clock")
                    .tag(SidebarItem.recentlyAdded)
                Label("歌手", systemImage: "music.microphone")
                    .tag(SidebarItem.artists)
                Label("專輯", systemImage: "square.stack")
                    .tag(SidebarItem.albums)
                Label("歌曲", systemImage: "music.note")
                    .tag(SidebarItem.songs)
                Label("類型", systemImage: "guitars")
                    .tag(SidebarItem.genres)
                Label("作曲者", systemImage: "music.quarternote.3")
                    .tag(SidebarItem.composers)
                Label("合輯", systemImage: "person.2")
                    .tag(SidebarItem.compilations)
                Label("未匹配曲目／專輯", systemImage: "questionmark.circle")
                    .badge(model.index.unmatchedTracks.count)
                    .lineLimit(1)
                    .tag(SidebarItem.unmatched)
                Label("收件匣", systemImage: "tray.and.arrow.down")
                    .badge(inbox.reviewCount)
                    .tag(SidebarItem.inbox)
                ForEach(folderPlaylists.playlists) { playlist in
                    Label(playlist.name, systemImage: "folder")
                        .lineLimit(1)
                        .tag(SidebarItem.folderPlaylist(playlist.id))
                        .contextMenu {
                            Button("移除播放列表") { model.removeFolderPlaylist(playlist) }
                        }
                }
            } header: {
                HStack {
                    Text("本地音樂庫")
                    Spacer()
                    Button(action: chooseFolderPlaylist) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("把資料夾加入成播放列表")
                    .accessibilityLabel("把資料夾加入成播放列表")
                }
            }

            Section("Apple Music") {
                Label("最近加入", systemImage: "clock")
                    .tag(SidebarItem.musicRecent)
                ForEach(playlists.playlists) { playlist in
                    Label(playlist.name, systemImage: playlist.isSmart ? "gearshape" : "music.note.list")
                        .lineLimit(1)
                        .tag(SidebarItem.playlist(playlist.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarSearchField(text: $navigation.searchText)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func chooseFolderPlaylist() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "建立播放列表")
        panel.message = String(localized: "選擇音樂庫裡的資料夾")
        panel.directoryURL = library.folders.first.map { URL(fileURLWithPath: $0) }
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        let prefix = LocalLibrary.pathPrefix(of: folder)
        if library.folders.contains(where: { prefix.hasPrefix(LocalLibrary.pathPrefix(of: $0)) }) {
            model.openFolderPlaylist(for: folder)
        }
        else {
            let alert = NSAlert()
            alert.messageText = String(localized: "這個資料夾不在音樂庫裡")
            alert.informativeText = String(localized: "請先到設定把它加入本地音樂資料夾。")
            alert.runModal()
        }
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            navigation.selection
        } set: { item in
            if let item { navigation.open(item) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            settingsButton
            HStack(spacing: 6) {
                if library.isScanning || playlists.syncState == .syncing {
                    ProgressView().controlSize(.mini)
                    Text(library.isScanning ? "正在掃描本地音檔" : "正在同步 Apple Music")
                }
                else if case .failed(let reason) = playlists.syncState {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(reason).lineLimit(2)
                }
                else {
                    Text("\(library.tracks.count) 首本地音檔")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var settingsButton: some View {
        Button {
            navigation.open(.settings)
        } label: {
            Label("設定", systemImage: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(navigation.selection == .settings ? Color.primary.opacity(0.1) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 工具列隱藏後系統的搜尋欄不一定還在，自己畫一個行為才固定
struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜尋", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                    isFocused = false
                }
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
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            Button("") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        }
    }
}
