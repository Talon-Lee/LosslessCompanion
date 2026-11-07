//
//  QueueView.swift
//  LosslessCompanion
//
//  待播清單分成已播放、正在播放、接下來。打開時第一列就是正在播放的歌，已播放的在上面，往上捲才看得到。
//  接下來的歌可以拖曳排序：放開才真的改動佇列，引擎才不會每移動一格就重排一次。
//

import AppKit
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: NavigationModel
    @GestureState private var drag: QueueDrag?

    private static let rowHeight: CGFloat = 48
    private static let headingHeight: CGFloat = 30
    private static let currentAnchor = "current"

    var body: some View {
        let sections = QueueSections(count: player.queue.count, currentIndex: player.currentIndex)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待播清單")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                if !sections.upcoming.isEmpty {
                    Button("清除待播") { player.clearUpcoming() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help("清除接下來的 \(sections.upcoming.count) 首，正在播放的歌不受影響")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if player.queue.isEmpty {
                ContentUnavailableView("目前沒有歌曲", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                list(sections)
            }
        }
    }

    private func list(_ sections: QueueSections) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !sections.played.isEmpty {
                            heading(String(localized: "已播放"))
                            rows(sections.played, in: .played)
                        }
                        if let current = sections.current {
                            heading(String(localized: "正在播放"))
                                .id(Self.currentAnchor)
                            rows(current..<(current + 1), in: .current)
                        }
                        if !sections.upcoming.isEmpty {
                            heading(String(localized: "接下來"))
                            upcomingRows(sections)
                        }
                        // 後面的歌不夠一頁時也要留白，「正在播放」才捲得到最上面
                        Color.clear.frame(height: tailSpace(sections, viewport: geometry.size.height))
                    }
                    .padding(.horizontal, 8)
                }
                .onAppear { showCurrent(proxy) }
                .onChange(of: player.currentItem?.id) { showCurrent(proxy) }
            }
        }
    }

    private func tailSpace(_ sections: QueueSections, viewport: CGFloat) -> CGFloat {
        let below = CGFloat(sections.upcoming.count + 1) * Self.rowHeight + Self.headingHeight * 2
        return max(0, viewport - below)
    }

    /// 等這一輪版面排好才捲得過去
    private func showCurrent(_ proxy: ScrollViewProxy) {
        #if DEBUG
        // 說明文件的圖片要拍到已播放那一段
        if ProcessInfo.processInfo.environment["LC_PREVIEW_QUEUE_TOP"] != nil { return }
        #endif
        DispatchQueue.main.async { proxy.scrollTo(Self.currentAnchor, anchor: .top) }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: Self.headingHeight, alignment: .bottomLeading)
            .padding(.bottom, 2)
    }

    private func rows(_ range: Range<Int>, in section: QueueRowKey.Section) -> some View {
        ForEach(keys(range, in: section), id: \.self) { row($0.index).opacity(section == .played ? 0.5 : 1) }
    }

    /// 只用位置當識別，換一份佇列時 LazyVStack 會沿用舊的列，顯示的歌和實際的對不上。
    /// 段落也要算進去：同一列從「正在播放」移到「已播放」時識別不變，LazyVStack 會把舊畫面搬過去，
    /// 播放動畫就留在已播放的歌上
    private func keys(_ range: Range<Int>, in section: QueueRowKey.Section) -> [QueueRowKey] {
        range.map { QueueRowKey(index: $0, itemID: player.queue[$0].id, section: section) }
    }

    private func row(_ index: Int) -> some View {
        let item = player.queue[index]
        let isCurrent = index == player.currentIndex
        return QueueRow(item: item, isCurrent: isCurrent, isPlaying: isCurrent && player.status == .playing) {
            player.jump(to: index)
        } onArtwork: {
            if isCurrent { player.togglePause() }
            else { player.jump(to: index) }
        }
        .contextMenu {
            if let album = model.localAlbum(for: item) {
                Button("前往本地音檔") {
                    navigation.showsPlayer = false
                    navigation.open(.album(album))
                }
                if let file = album.tracks.first(where: { $0.path == item.local?.path }) ?? item.local {
                    Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                }
                if !isCurrent { Divider() }
            }
            if !isCurrent {
                Button("從待播清單移除") { player.remove(at: index) }
            }
        }
    }

    private func upcomingRows(_ sections: QueueSections) -> some View {
        let target = drag.map { sections.dropIndex(from: $0.index, offset: $0.offset, rowHeight: Self.rowHeight) }
        return ForEach(keys(sections.upcoming, in: .upcoming), id: \.self) { key in
            let index = key.index
            let isDragged = drag?.index == index
            row(index)
                .background {
                    if isDragged {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    }
                }
                .offset(y: offset(of: index, target: target))
                .zIndex(isDragged ? 1 : 0)
                // 放開時內容已經換好，其他列要直接歸位
                .animation(drag == nil || isDragged ? nil : .easeOut(duration: 0.12), value: target)
                .gesture(reorderGesture(index, sections))
        }
    }

    private func offset(of index: Int, target: Int?) -> CGFloat {
        guard let drag, let target else { return 0 }
        if index == drag.index { return drag.offset }
        return CGFloat(QueueSections.shift(of: index, draggingFrom: drag.index, to: target)) * Self.rowHeight
    }

    private func reorderGesture(_ index: Int, _ sections: QueueSections) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in
                state = QueueDrag(index: index, offset: value.translation.height)
            }
            .onEnded { value in
                player.moveUpcoming(from: index, to: sections.dropIndex(from: index, offset: value.translation.height,
                                                                        rowHeight: Self.rowHeight))
            }
    }
}

private struct QueueRowKey: Hashable {
    enum Section { case played, current, upcoming }

    let index: Int
    let itemID: String
    let section: Section
}

private struct QueueDrag: Equatable {
    let index: Int
    let offset: CGFloat
}

private struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onArtwork: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false

    private var backgroundFill: Color {
        if isHovering { return Color.primary.opacity(0.08) }
        return isCurrent ? Color.primary.opacity(0.055) : .clear
    }

    var body: some View {
        HStack(spacing: 9) {
            TrackArtworkButton(source: item.artworkSource, side: 36, title: item.title, isCurrent: isCurrent,
                               isPlaying: isPlaying, isHovering: isHovering, action: onArtwork)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isFavorite(item) { FavoriteStar() }
            RouteChip(route: item.route)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundFill)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
    }
}
