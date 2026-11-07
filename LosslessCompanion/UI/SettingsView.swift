//
//  SettingsView.swift
//  LosslessCompanion
//
//  設定是主視窗裡的一頁：全螢幕時另開視窗會跳到別的桌面。
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var review: MatchReviewStore
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var model: AppModel

    @State private var devices = [OutputDeviceInfo]()
    @State private var isConfirmingClear = false

    private static let maxWidth: CGFloat = 760
    private static let contactEmail = "talonlee218@gmail.com"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageTitle(title: String(localized: "設定"))
                .padding([.horizontal, .top], Theme.pagePadding)
            Form {
                foldersSection
                appearanceSection
                outputSection
                deviceSection
                reviewSection
                OrganizeHistorySection()
                artworkSection
                appleMusicSection
                aboutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: Self.maxWidth)
            .padding(.horizontal, Theme.pagePadding - 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            devices = OutputDeviceInfo.all()
            model.refreshDeviceVolume()
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(library.folders, id: \.self) { folder in
                FolderRow(folder: folder, canRemove: library.folders.count > 1) {
                    library.setFolders(library.folders.filter { $0 != folder })
                }
            }
            HStack {
                Button("加入資料夾…", action: addFolders)
                Button("重新掃描") { library.rescan() }
                    .disabled(library.isScanning)
                if library.isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(library.tracks.count) 首可播放，\(library.hiddenCount) 個檔案已隱藏")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("本地音樂資料夾")
        } footer: {
            Text("會讀取這些資料夾與裡面所有子資料夾的音檔。不能以 Bit-Perfect 播放的檔案會隱藏。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceSection: some View {
        Section("外觀與語言") {
            Picker("配色", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Picker("語言", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
            if settings.language != settings.launchLanguage {
                HStack {
                    Text("重新開啟 App 後才會換成新的語言，目前的播放會停止。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新開啟") { model.relaunch() }
                }
            }
        }
    }

    private var outputSection: some View {
        Section(String(localized: "section.playback", defaultValue: "播放")) {
            Picker("獨佔輸出裝置", selection: $settings.deviceUID) {
                Text("跟隨系統預設").tag(String?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            Picker("預設播放來源", selection: $settings.defaultPreference) {
                ForEach(RoutePreference.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Text(settings.defaultPreference.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("關閉視窗後繼續在背景執行", isOn: $settings.keepsRunningInBackground)
            Text("開啟時，Apple Music 播放串流仍會自動切換 DAC 取樣率。關閉後，關掉視窗就會結束 App。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("驗證串流樣本", isOn: $settings.verifiesStreamSamples)
            Text("檢查 Music 的輸出有沒有被改動。需要系統音訊錄音權限，只計算，不儲存音訊。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 每台 DAC 鎖定時鐘的速度不同，所以這些設定跟著裝置走
    @ViewBuilder
    private var deviceSection: some View {
        if let uid = model.routing.currentUID {
            Section("\(model.outputDeviceName) 的獨佔設定") {
                Picker("切換取樣率後等待", selection: option(\.lockInSeconds, uid: uid)) {
                    ForEach(OutputOptions.lockInChoices, id: \.self) { seconds in
                        Text(seconds == OutputOptions.defaultLockIn ? "\(seconds.formatted()) 秒（預設）" : "\(seconds.formatted()) 秒")
                            .tag(seconds)
                    }
                }
                Text("歌曲開頭被切掉時調長。這段靜音送在音樂之前，不影響 Bit-Perfect。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                LabeledContent("DAC 音量", value: Format.deviceVolume(model.deviceVolume))
                Toggle("播放時固定為 100%", isOn: option(\.forcesMaxVolume, uid: uid))
                    .disabled(model.deviceVolume == nil)
                Text("macOS 音量滑桿控制的是 DAC 自己的音量，不是 100% 時 DAC 可能會縮放數位訊號。開啟後本地與 Apple Music 播放時都拉到最大，停止時還原；串流的大小聲用播放列的滑桿調整。DAC 直接推耳機或主動喇叭時聲音會突然變大，請先確認後級音量。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func option<Value>(_ keyPath: WritableKeyPath<OutputOptions, Value>, uid: String) -> Binding<Value> {
        Binding {
            settings.outputOptions(for: uid)[keyPath: keyPath]
        } set: { value in
            var options = settings.outputOptions(for: uid)
            options[keyPath: keyPath] = value
            settings.setOutputOptions(options, for: uid)
        }
    }

    private var reviewSection: some View {
        Section("未匹配校閱") {
            LabeledContent("手動連結", value: String(localized: "\(review.decisions.links.count) 首"))
            LabeledContent("標記為僅本地", value: String(localized: "\(review.decisions.localOnly.count) 首"))
            HStack {
                Button("前往校閱") { navigation.open(.unmatched) }
                Button("清除所有校閱…") { isConfirmingClear = true }
                    .disabled(review.decisions.isEmpty)
            }
            .confirmationDialog("清除所有手動連結與「僅本地」標記？", isPresented: $isConfirmingClear) {
                Button("清除", role: .destructive) { review.clearAll() }
            } message: {
                Text("這些曲目會回到未匹配清單。音檔與 Apple Music 資料庫都不受影響。")
            }
        }
    }

    private var artworkSection: some View {
        Section("封面") {
            HStack {
                Button("重新讀取所有封面") { ArtworkStore.shared.clearCache() }
                Spacer()
                Text("更換過檔案裡的封面後使用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appleMusicSection: some View {
        Section("Apple Music") {
            HStack {
                Button("立即同步播放列表") { playlists.sync() }
                    .disabled(playlists.syncState == .syncing)
                Spacer()
                if let lastSynced = playlists.lastSynced {
                    Text("上次同步 \(lastSynced.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let reason) = playlists.syncState {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle("Hog 模式", isOn: $settings.usesHogBridge)
                .disabled(!StreamBridgeClient.isInstalled)
            Text(hogModeDetail)
                .font(.footnote)
                .foregroundStyle(model.bridgeProblem == nil ? Color.secondary : Color.orange)
            if StreamRateMatcher.isLosslessSwitcherRunning {
                Text("LosslessSwitcher 正在執行，串流的取樣率切換交給它處理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hogModeDetail: String {
        if !StreamBridgeClient.isInstalled {
            return String(localized: "需要先安裝 LosslessCompanion Bridge 虛擬裝置。")
        }
        if let problem = model.bridgeProblem {
            return String(localized: "橋接沒有啟動：\(problem)。這段期間改用一般方式播放。")
        }
        if let status = model.bridgeStatus {
            return String(localized: "橋接中：\(Format.sampleRate(status.sampleRate))，四捨五入到 \(status.sourceBits)-bit。")
        }
        return String(localized: "Apple Music 輸出到虛擬裝置，由本 App 獨佔 DAC 原樣轉送，取樣率跟著每首歌切換。Music 停止 10 分鐘後交還 DAC。")
    }

    private var aboutSection: some View {
        Section("關於") {
            VStack(alignment: .leading, spacing: 10) {
                BrandBanner()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous))
                Text("LosslessCompanion \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(Self.contactEmail, destination: URL(string: "mailto:\(Self.contactEmail)")!)
                    .font(.footnote)
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "加入")
        panel.message = String(localized: "選擇要加入音樂庫的資料夾")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !library.folders.contains($0) }
        if !added.isEmpty { library.setFolders(library.folders + added) }
    }
}

private struct FolderRow: View {
    let folder: String
    let canRemove: Bool
    let onRemove: () -> Void

    @EnvironmentObject private var library: LocalLibrary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if library.isReachable(folder) {
                        Text("\(library.trackCount(in: folder)) 首")
                    }
                    else {
                        Text("目前無法讀取，保留上次的索引")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在 Finder 中顯示")
            .accessibilityLabel("在 Finder 中顯示")
            Button("移除", action: onRemove)
                .disabled(!canRemove)
        }
    }
}
