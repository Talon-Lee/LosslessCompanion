//
//  PlayerPage.swift
//  LosslessCompanion
//
//  播放視窗：只顯示目前這首歌。版面沿用 LosslessSwitcher 的播放卡片，
//  封面、規格小標籤、進度與圓形暫停鍵，放大成整頁。
//

import CoreImage
import SwiftUI

struct PlayerPage: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel
    @State private var showsSignalPath = false

    private static let infoWidth: CGFloat = 400
    private static let columnSpacing: CGFloat = 56
    private static let maxArtwork: CGFloat = 600
    private static let minArtwork: CGFloat = 260
    private static let verticalMargin: CGFloat = 170
    private static let horizontalMargin: CGFloat = 120

    private func artworkSide(in size: CGSize) -> CGFloat {
        let available = min(size.height - Self.verticalMargin, size.width - Self.infoWidth - Self.columnSpacing - Self.horizontalMargin)
        return max(Self.minArtwork, min(available, Self.maxArtwork))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                if let item = player.currentItem {
                    PlayerBackdrop(source: item.artworkSource)
                    HStack(spacing: Self.columnSpacing) {
                        let side = artworkSide(in: geometry.size)
                        ArtworkView(source: item.artworkSource, side: side, radius: 14)
                            .shadow(color: .black.opacity(0.3), radius: 28, y: 14)
                            .contextMenu { NowPlayingMenu() }
                        info(for: item)
                            .frame(width: Self.infoWidth, alignment: .leading)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                navigation.showsPlayer = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("回到音樂庫")
            .accessibilityLabel("關閉播放視窗")
            .padding(22)
        }
        .onChange(of: player.currentItem == nil) { _, isEmpty in
            if isEmpty { navigation.showsPlayer = false }
        }
    }

    private func info(for item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if model.isFavorite(item) { FavoriteStar(size: 15) }
                    Text(item.title)
                        .font(.system(size: 28, weight: .bold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            specButton(for: item)
            PlayerProgress()
                .padding(.top, 6)
            PlayerTransport()
            if let message = player.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 點一下展開完整的訊號路徑
    private func specButton(for item: QueueItem) -> some View {
        Button {
            showsSignalPath.toggle()
        } label: {
            HStack(spacing: 6) {
                RouteChip(route: item.route)
                ForEach(specs(for: item), id: \.self) { SpecChip(text: $0) }
                if item.route == .local, let path = player.outputPath { PathChip(path: path) }
            }
        }
        .buttonStyle(.plain)
        .help("訊號路徑")
        .accessibilityLabel("訊號路徑")
        .popover(isPresented: $showsSignalPath, arrowEdge: .bottom) {
            SignalPathView()
        }
    }

    private func specs(for item: QueueItem) -> [String] {
        if item.route == .local, let format = player.sourceFormat {
            var specs = [Format.sampleRate(format.sampleRate), "\(format.bitsPerSample)-bit"]
            if let track = item.local { specs.append(Format.codec(of: track.url)) }
            return specs
        }
        if let format = model.streamFormat {
            return [Format.sampleRate(format.sampleRate), "\(format.bitDepth)-bit", "ALAC"]
        }
        return []
    }
}

/// 縮圖放大成整頁會看得出方塊，先把圖片本身模糊再放大
private struct PlayerBackdrop: View {
    let source: ArtworkSource

    @ObservedObject private var store = ArtworkStore.shared
    @State private var image: NSImage?

    private static let thumbnailSide: CGFloat = 64
    private static let blurSigma: Double = 9

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .saturation(1.25)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(0.3)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
        .task(id: ArtworkRequest(source: source, generation: store.generation)) {
            image = await store.image(for: source, side: Self.thumbnailSide).flatMap(Self.blurred)
        }
    }

    private static func blurred(_ image: NSImage) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: source)
        // 邊緣延伸出去再模糊，四周才不會淡成透明
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: blurSigma).cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent).map { NSImage(cgImage: $0, size: image.size) }
    }
}

private struct SpecChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

private struct PathChip: View {
    let path: OutputPath

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(path == .directInteger ? Theme.accent : Color.orange)
                .frame(width: 6, height: 6)
            Text(path == .directInteger ? "整數直通" : "Float32")
                .font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// 位置更新很頻繁，獨立出來，其他文字才不會跟著重算
private struct PlayerProgress: View {
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        VStack(spacing: 3) {
            Scrubber()
            HStack {
                Text(Format.time(clock.elapsed))
                Spacer()
                Text("-" + Format.time(max(0, clock.duration - clock.elapsed)))
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

private struct PlayerTransport: View {
    @EnvironmentObject private var player: PlaybackCoordinator

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            control("backward.fill", label: String(localized: "上一首"), size: 20) { player.previous() }
            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .background(Color.primary.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.status == .preparing)
            .accessibilityLabel(player.status == .playing ? "暫停" : "播放")
            control("forward.fill", label: String(localized: "下一首"), size: 20) { player.next() }
            Spacer()
        }
        .overlay(alignment: .leading) {
            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重複播放")
            .accessibilityLabel("重複播放")
        }
        .overlay(alignment: .trailing) {
            control("stop.fill", label: String(localized: "停止"), size: 13) { player.stop() }
                .foregroundStyle(.secondary)
                .help("停止並交還 DAC")
        }
    }

    private func control(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
