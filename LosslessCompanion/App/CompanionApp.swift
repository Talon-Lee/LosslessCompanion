//
//  CompanionApp.swift
//  LosslessCompanion
//

import AppKit
import Combine
import SwiftUI

/// 同一個執行檔也是獨佔輸出的輔助程序，要在 SwiftUI 啟動前判斷
@main
enum CompanionEntry {
    static func main() {
        if CommandLine.arguments.contains(BitPerfectHelper.launchFlag) {
            BitPerfectHelper.run()
        }
        if CommandLine.arguments.contains(StreamBridgeHelper.launchFlag) {
            StreamBridgeHelper.run()
        }
        CompanionApp.main()
    }
}

struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate

    private var model: AppModel { .shared }

    var body: some Scene {
        // 用 WindowGroup：單一 Window 場景在 App 不隨視窗結束時，關閉鈕會被停用
        WindowGroup("LosslessCompanion", id: "main") {
            RootView()
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
                .environmentObject(model.inbox)
                .environmentObject(model.folderPlaylists)
                .tint(Theme.accent)
                // 全螢幕時工具列是獨立的不透明視窗，會蓋住貼齊頂端的播放列，要等游標移到頂端才出現
                .windowToolbarFullScreenVisibility(.onHover)
        }
        .defaultSize(width: 1280, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            SidebarCommands()
            PlayerCommands(player: model.player)
            // 只有一個音樂庫，開第二個視窗沒有意義
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                SettingsMenuButton(navigation: model.navigation)
            }
        }
    }
}

struct SettingsMenuButton: View {
    let navigation: NavigationModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("設定…") {
            navigation.open(.settings)
            // 關掉視窗後 App 還留在背景，這時要重新開一個；已有視窗時再開會多一個
            if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                openWindow(id: "main")
            }
            NSApp.activate()
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private static let minimumVisibleSize = NSSize(width: 200, height: 100)

    private var appearanceObserver: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        appearanceObserver = AppSettings.shared.$appearance.sink { NSApp.appearance = $0.nsAppearance }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if case .testing = AppRuntime.current {
            NSApp.setActivationPolicy(.prohibited)
        }
        if AppRuntime.current.isLive {
            DispatchQueue.main.async(execute: bringWindowsOnScreen)
        }
        #if DEBUG
        DebugControl.shared.start()
        if case .preview = AppRuntime.current {
            PreviewHarness.start(model: .shared)
        }
        if ProcessInfo.processInfo.environment["LC_LIVE_SMOKE"] != nil {
            PreviewHarness.runLiveSmoke(model: .shared)
        }
        #endif
    }

    /// 記住的位置可能在已拔除的外接螢幕上，看不到視窗就無從操作
    private func bringWindowsOnScreen() {
        for window in NSApp.windows where window.canBecomeMain {
            let isReachable = NSScreen.screens.contains { screen in
                let visible = screen.visibleFrame.intersection(window.frame)
                return visible.width >= Self.minimumVisibleSize.width && visible.height >= Self.minimumVisibleSize.height
            }
            if !isReachable { window.center() }
        }
    }

    /// 取代 LosslessSwitcher 後，關掉視窗也要繼續切換取樣率，所以預設和 Apple Music 一樣留在背景
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.keepsRunningInBackground
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.prepareForTermination()
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var player: PlaybackCoordinator

    var body: some Commands {
        CommandMenu("控制") {
            Button(player.status == .playing ? "暫停" : "播放") { player.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.status == .idle)
            Button("下一首") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.status == .idle)
            Button("上一首") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.status == .idle)
            Divider()
            Button("停止") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(player.status == .idle)
        }
    }
}
