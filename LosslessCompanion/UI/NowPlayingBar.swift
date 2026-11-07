//
//  NowPlayingBar.swift
//  LosslessCompanion
//
//  視窗頂端的播放列：左邊傳輸鍵、中間顯示目前歌曲與訊號資訊、右邊音量與待播清單。
//  系統工具列的高度放不下三行資訊，所以自己排，版面對應 Apple Music 的 LCD。
//

import SwiftUI

struct NowPlayingBar: View {
    @Binding var showsQueue: Bool
    var leadingInset: CGFloat = 0

    private static let height: CGFloat = 96
    /// 兩側一樣寬，中間的資訊欄才會在正中央
    private static let sideWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 18) {
            TransportControls()
                .frame(width: Self.sideWidth, alignment: .leading)
            NowPlayingDisplay()
                .frame(minWidth: 300, maxWidth: 780)
                .frame(maxWidth: .infinity)
            HStack(spacing: 14) {
                VolumeControl()
                Button {
                    showsQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(showsQueue ? Color.primary : Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("待播清單")
                .accessibilityLabel("待播清單")
            }
            .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .padding(.leading, 18 + leadingInset)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

struct TransportControls: View {
    @EnvironmentObject private var player: PlaybackCoordinator

    private var isIdle: Bool { player.status == .idle }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode.symbol)
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.primary)
                    .font(.system(size: 13))
            }
            .help("重複播放")
            .accessibilityLabel("重複播放")

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15))
            }
            .accessibilityLabel("上一首")
            .disabled(isIdle)

            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .frame(width: 26)
            }
            .accessibilityLabel(player.status == .playing ? "暫停" : "播放")
            .disabled(isIdle || player.status == .preparing)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15))
            }
            .accessibilityLabel("下一首")
            .disabled(isIdle)
        }
        .buttonStyle(.plain)
    }
}

struct NowPlayingDisplay: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel
    @State private var showsSignalPath = false

    private static let height: CGFloat = 80

    var body: some View {
        HStack(spacing: 0) {
            if let item = player.currentItem {
                ArtworkView(source: item.artworkSource, side: Self.height, radius: 0)
                    .overlay {
                        if player.status == .preparing { ProgressView().controlSize(.small) }
                    }
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        if model.isFavorite(item) { FavoriteStar(size: 10) }
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(subtitle(for: item))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    signalButton(for: item)
                    PlaybackProgress()
                        .padding(.top, 1)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
            }
            else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if player.currentItem != nil { navigation.showsPlayer = true }
        }
        .help(player.currentItem == nil ? "" : "打開播放視窗")
        .contextMenu { NowPlayingMenu() }
    }

    private func subtitle(for item: QueueItem) -> String {
        if let message = player.message { return message }
        return [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var qualityText: String {
        if player.activeRoute == .local, let format = player.sourceFormat {
            return Format.quality(rate: format.sampleRate, bits: format.bitsPerSample)
        }
        if let format = model.streamFormat {
            return Format.quality(rate: format.sampleRate, bits: format.bitDepth)
        }
        return String(localized: "規格未知")
    }

    /// 點一下展開完整的訊號路徑
    private func signalButton(for item: QueueItem) -> some View {
        Button {
            showsSignalPath.toggle()
        } label: {
            HStack(spacing: 7) {
                RouteChip(route: item.route)
                Text(qualityText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(model.outputDeviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.route == .local, model.isDeviceAttenuated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("DAC 音量未達 100%")
                }
                if item.route == .appleMusic, let warning = model.streamWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help(warning)
                        .accessibilityLabel(warning)
                }
            }
        }
        .buttonStyle(.plain)
        .help("訊號路徑")
        .accessibilityLabel("訊號路徑")
        .accessibilityValue("\(item.route == .local ? String(localized: "本地") : String(localized: "串流"))，\(qualityText)，\(model.outputDeviceName)")
        .popover(isPresented: $showsSignalPath, arrowEdge: .bottom) {
            SignalPathView()
        }
    }
}

/// 正在播放的歌曲的右鍵選單，播放列與播放視窗共用
struct NowPlayingMenu: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        if let album = player.currentItem.flatMap(model.localAlbum(for:)) {
            Button("前往本地專輯") {
                navigation.showsPlayer = false
                navigation.open(.album(album))
            }
        }
        if let album = player.currentItem?.stream.flatMap({ model.musicAlbum(forTrackID: $0.trackID) }) {
            Button("前往 Apple Music 專輯") {
                navigation.showsPlayer = false
                navigation.open(.musicAlbum(album))
            }
        }
    }
}

struct FavoriteStar: View {
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .accessibilityLabel("喜好項目")
            .help("喜好項目")
    }
}

struct RouteChip: View {
    let route: PlaybackRoute

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(route == .local ? Theme.accent : Color.clear)
                .strokeBorder(route == .local ? Color.clear : Color.secondary, lineWidth: 1)
                .frame(width: 6, height: 6)
            Text(route == .local ? "本地" : "串流")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(route == .local ? .primary : .secondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// 時間與進度線。播放位置更新很頻繁，獨立成一個視圖，其他文字才不會跟著重算
struct PlaybackProgress: View {
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.time(clock.elapsed))
                .frame(width: 34, alignment: .trailing)
            Scrubber()
            Text("-" + Format.time(max(0, clock.duration - clock.elapsed)))
                .frame(width: 38, alignment: .leading)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// 進度線，懸停時變粗，可拖曳
struct Scrubber: View {
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var player: PlaybackCoordinator
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = dragFraction ?? (clock.duration > 0 ? min(1, clock.elapsed / clock.duration) : 0)
            ZStack(alignment: .leading) {
                Color.clear.contentShape(Rectangle())
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: isHovering ? 5 : 3)
                Capsule()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: geometry.size.width * fraction, height: isHovering ? 5 : 3)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = max(0, min(1, $0.location.x / geometry.size.width)) }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        player.seek(to: fraction * clock.duration)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 10)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct VolumeControl: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var volume: MusicVolume

    private var isExclusive: Bool { player.activeRoute == .local }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExclusive ? "lock.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { isExclusive ? 100 : volume.value }, set: { volume.set($0) }), in: 0...100)
                .controlSize(.mini)
                .frame(width: 78)
                .disabled(isExclusive)
        }
        .help(isExclusive ? "獨佔輸出不經過軟體音量，請用 DAC 或耳擴調整" : "Apple Music 音量")
    }
}

struct SignalPathView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if player.activeRoute == .local {
                if model.isDeviceAttenuated {
                    header(String(localized: "獨佔輸出，DAC 音量未達 100%"), color: .orange, symbol: "exclamationmark.triangle.fill")
                }
                else {
                    header(String(localized: "Bit-Perfect 獨佔輸出"), color: .primary, symbol: "checkmark.seal.fill")
                }
                step(String(localized: "音訊規格"), localSource)
                step(String(localized: "解碼"), player.currentItem?.local.map { Format.codec(of: $0.url) } ?? "PCM")
                step(String(localized: "輸出"), player.outputPath == .directInteger ? String(localized: "非混音整數格式，直接交給驅動程式") : String(localized: "32 位元浮點，由 HAL 轉為硬體格式"))
                step(String(localized: "系統混音"), String(localized: "已略過"))
                step(String(localized: "裝置"), model.outputDeviceName)
                step(String(localized: "DAC 音量"), model.isDeviceAttenuated ? String(localized: "\(Format.deviceVolume(model.deviceVolume))，DAC 可能會縮放訊號") : Format.deviceVolume(model.deviceVolume))
            }
            else {
                let verdict = model.streamVerdict
                header(verdict.title, color: verdict == .processed ? .orange : verdict == .unknown ? .secondary : .primary,
                       symbol: verdict == .processed ? "exclamationmark.triangle.fill" : verdict == .unknown ? "dot.radiowaves.left.and.right" : "checkmark.seal")
                ForEach(model.streamRows) { checkRow($0) }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear {
            model.refreshDeviceVolume()
            model.refreshStreamPath()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if player.activeRoute != .local { model.refreshStreamPath() }
        }
    }

    private var localSource: String {
        guard let format = player.sourceFormat else { return String(localized: "準備中") }
        return Format.quality(rate: format.sampleRate, bits: format.bitsPerSample)
    }

    private func header(_ title: String, color: Color, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    private func checkRow(_ row: StreamCheckRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(row.value)
                .foregroundStyle(row.state == .warning ? .orange : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if row.state != .unknown {
                Image(systemName: row.state == .ok ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(row.state == .ok ? Color.secondary : Color.orange)
            }
        }
        .font(.system(size: 12))
    }

    private func step(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}
