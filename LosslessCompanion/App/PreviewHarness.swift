//
//  PreviewHarness.swift
//  LosslessCompanion
//
//  僅 Debug 組建：設定 LC_PREVIEW 後只顯示快取資料，用假的傳輸層模擬播放中的畫面，
//  把頁面畫成圖片檢查版面。不會控制 Music，也不會開啟音訊輸出。
//  原生側欄與工具列的材質畫不進圖片，這裡用相同元件排出版面。
//  正式執行的實機測試由 DebugControl 負責。
//

#if DEBUG
import AppKit
import SwiftUI

enum PreviewHarness {
    private static var navigation: NavigationModel { AppModel.shared.navigation }
    private static var window: NSWindow?
    /// 長頁面可以用 LC_PREVIEW_HEIGHT 拉高，一次看完；待播清單打開時版面比較寬，用 LC_PREVIEW_WIDTH 加寬
    private static let size = NSSize(width: Double(environment["LC_PREVIEW_WIDTH"] ?? "") ?? 1280,
                                     height: Double(environment["LC_PREVIEW_HEIGHT"] ?? "") ?? 840)

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// LC_PREVIEW 的格式：頁面[:參數]，例如 playlist:2、search:周杰倫、album:10
    static func start(model: AppModel) {
        NSApp.setActivationPolicy(.accessory)
        let usesRealWindow = environment["LC_PREVIEW_ROOT"] != nil
        if usesRealWindow {
            // 真實視窗畫不成圖片，這個模式只用來檢查版面會不會空轉。螢幕外的視窗輔助使用讀不到，要操作時排到最後面
            if environment["LC_PREVIEW_AX"] != nil { NSApp.windows.first?.orderBack(nil) }
            else { NSApp.windows.first?.setFrameOrigin(NSPoint(x: -3000, y: 200)) }
        }
        else {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
        if let mode = environment["LC_PREVIEW_STREAM"] { model.injectPreviewStreamCheck(hasProblem: mode == "warn") }
        if let path = environment["LC_PREVIEW_RAW"], let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            model.playlists.debugReplace(MusicPlaylistParser.parse(raw.trimmingCharacters(in: .newlines)))
        }
        // 專輯要等比對跑完才有資料，LC_PREVIEW_WAIT 可以多等一下
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(environment["LC_PREVIEW_WAIT"] ?? "") ?? 2.5)) {
            if usesRealWindow { navigate(model) }
            else { render(model) }
        }
    }

    /// 走正式的啟動流程但不顯示視窗：同步歌單、啟動監看，幾秒後回報並正常結束。不發出任何播放指令
    static func runLiveSmoke(model: AppModel) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.windows.forEach { $0.setFrameOrigin(NSPoint(x: -3000, y: 200)) }
        // 用 DebugControl 實測時值設成要跑的秒數，一般冒煙測試設 1
        let seconds = Double(environment["LC_LIVE_SMOKE"] ?? "").flatMap { $0 > 1 ? $0 : nil } ?? 9
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let entries = model.playlists.playlists.reduce(0) { $0 + $1.entries.count }
            print("LIVE playlists=\(model.playlists.playlists.count) entries=\(entries) sync=\(model.playlists.syncState)",
                  "matches=\(model.matches.count) tracks=\(model.library.tracks.count) hidden=\(model.library.hiddenCount)",
                  "albums=\(model.albums.count) artists=\(model.artists.count) volume=\(model.musicVolume.value)",
                  "status=\(model.player.status) lsRunning=\(StreamRateMatcher.isLosslessSwitcherRunning)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static func render(_ model: AppModel) {
        navigate(model)
        let appearance = environment["LC_PREVIEW_APPEARANCE"] == "dark" ? NSAppearance.Name.darkAqua : .aqua
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        // LC_PREVIEW_SPLASH：只畫開啟時的標誌畫面
        let base = environment["LC_PREVIEW_SPLASH"] != nil ? AnyView(LaunchSplash()) : AnyView(PreviewComposite())
        let content = base
            .environment(\.colorScheme, scheme)
            .environmentObject(navigation)
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.library)
            .environmentObject(model.playlists)
            .environmentObject(model.player)
            .environmentObject(model.player.clock)
            .environmentObject(model.musicVolume)
            .environmentObject(model.review)
            .environmentObject(model.playCounts)
            .environmentObject(model.organizer)
            .environmentObject(model.folderPlaylists)
            .tint(Theme.accent)
            .frame(width: size.width, height: size.height)
            .background(Color(white: scheme == .dark ? 0.12 : 0.98))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderBack(nil)
        self.window = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            guard let output = environment["LC_PREVIEW_OUT"],
                  let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            print("LC_DONE")
            fflush(stdout)
        }
    }

    /// 參數是專輯的位置或標題的一部分
    private static func album(named argument: String, in model: AppModel) -> AlbumGroup? {
        if let index = Int(argument) { return model.albums.indices.contains(index) ? model.albums[index] : nil }
        return model.albums.first { $0.title.contains(argument) }
    }

    private static func navigate(_ model: AppModel) {
        guard let page = environment["LC_PREVIEW"] else { return }
        let parts = page.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""

        switch parts[0] {
        case "albums": navigation.open(.albums)
        case "artists":
            navigation.open(.artists)
            if let index = Int(argument), model.artists.indices.contains(index) { navigation.open(.artist(model.artists[index])) }
        case "songs": navigation.open(.songs)
        case "recent": navigation.open(.recentlyAdded)
        case "genres": navigation.open(.genres)
        case "composers": navigation.open(.composers)
        case "compilations": navigation.open(.compilations)
        case "unmatched": navigation.open(.unmatched)
        case "musicrecent": navigation.open(.musicRecent)
        case "musicalbum":
            if let index = Int(argument), model.index.recentMusic.indices.contains(index) {
                navigation.open(.musicRecent)
                navigation.open(.musicAlbum(model.index.recentMusic[index]))
            }
        case "settings": navigation.open(.settings)
        case "review":
            navigation.open(.unmatched)
            // 比對要幾秒才跑完，太早開佇列是空的
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { navigation.review(model.reviewQueue) }
        case "playlist":
            let playlists = model.playlists.playlists
            if let index = Int(argument), playlists.indices.contains(index) {
                navigation.open(.playlist(playlists[index].id))
            }
        case "album":
            if let album = album(named: argument, in: model) {
                navigation.open(.albums)
                navigation.open(.album(album))
            }
        case "search":
            navigation.searchText = argument
        case "folder":
            // 隔離的假家目錄裡音樂庫根目錄不同，這裡直接取專輯的上一層
            if let index = Int(argument), model.albums.indices.contains(index) {
                model.openFolderPlaylist(for: URL(fileURLWithPath: model.albums[index].id).deletingLastPathComponent().path)
            }
        case "organize", "merge", "export":
            guard let album = album(named: argument, in: model) else { break }
            navigation.open(.albums)
            navigation.open(.album(album))
            // 比對要幾秒才跑完，太早開看不到 Apple Music 的資料
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                switch parts[0] {
                case "organize": navigation.organizeRequest = OrganizeSheetRequest(title: album.title, tracks: album.tracks)
                case "merge": navigation.mergeRequest = AlbumMergeSheetRequest(album: album)
                default: navigation.exportRequest = ExportSheetRequest(title: album.title, albums: [album])
                }
            }
        default:
            navigation.open(.home)
        }

        navigation.showsQueue = environment["LC_PREVIEW_QUEUE"] != nil
        if environment["LC_PREVIEW_PLAYING"] != nil,
           let playlist = model.playlists.playlists.first(where: { !$0.isSmart && !$0.entries.isEmpty }) {
            let entry = playlist.entries.first { model.match(for: $0) != nil } ?? playlist.entries[0]
            model.play(playlist, from: entry)
            if let index = Int(environment["LC_PREVIEW_JUMP"] ?? "") { model.player.jump(to: index) }
            model.player.clock.elapsed = model.player.clock.duration * 0.38
            navigation.showsPlayer = environment["LC_PREVIEW_PLAYER"] != nil
        }
    }
}

private struct PreviewComposite: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .padding(.top, 30)
                .frame(width: 236)
            Divider()
            VStack(spacing: 0) {
                NowPlayingBar(showsQueue: $navigation.showsQueue)
                Divider()
                HStack(spacing: 0) {
                    Group {
                        if let destination = navigation.path.last {
                            DestinationPage(destination: destination)
                        }
                        else {
                            MainPage()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if navigation.showsQueue {
                        Divider()
                        QueueView()
                            .frame(width: 320)
                    }
                }
            }
        }
        .overlay {
            if navigation.showsPlayer { PlayerPage() }
            if ProcessInfo.processInfo.environment["LC_PREVIEW_SIGNAL"] != nil {
                sheet { SignalPathView() }
            }
            // 不改排序設定，那會寫進使用者的偏好設定
            if ProcessInfo.processInfo.environment["LC_PREVIEW_RATES"] != nil {
                // 每一類只取幾張，一張圖看得到所有分類
                let sample = LibraryBrowser.rateGroups(from: AlbumSortKey.title.sorted(AppModel.shared.albums)).flatMap { $0.albums.prefix(5) }
                ScrollView { AlbumRateSections(albums: sample).padding(Theme.pagePadding) }
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            if ProcessInfo.processInfo.environment["LC_PREVIEW_DUPLICATES"] != nil {
                ScrollView { DuplicateList().padding(Theme.pagePadding) }
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            if let request = navigation.reviewRequest {
                sheet { MatchReviewSheet(request: request) }
            }
            if let request = navigation.organizeRequest {
                sheet { OrganizeSheet(request: request) }
            }
            if let request = navigation.mergeRequest {
                sheet { AlbumMergeSheet(request: request) }
            }
            if let request = navigation.exportRequest {
                sheet { ExportSheet(request: request) }
            }
        }
    }

    private func sheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 24)
    }
}
#endif
