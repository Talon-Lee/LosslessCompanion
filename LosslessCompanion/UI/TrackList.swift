//
//  TrackList.swift
//  LosslessCompanion
//
//  歌曲列表。欄位比例對應 Apple Music：封面與歌名、歌手、專輯、時長，隔列淡色底。
//

import SwiftUI

struct TrackRowModel: Identifiable, Equatable {
    let id: String
    let index: Int
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artwork: ArtworkSource
    let quality: (rate: Double, bits: Int)?
    let isStreamOnly: Bool
    let isDimmed: Bool
    var isFavorite = false
    /// 只有本地清單有這一欄
    var playCount: Int?

    static func == (lhs: TrackRowModel, rhs: TrackRowModel) -> Bool {
        lhs.id == rhs.id && lhs.index == rhs.index && lhs.isDimmed == rhs.isDimmed
            && lhs.quality?.rate == rhs.quality?.rate && lhs.isFavorite == rhs.isFavorite && lhs.playCount == rhs.playCount
    }
}

/// 列表寬度變窄時，歌名保留最多空間，太窄就收起專輯欄
struct TrackColumns: Equatable {
    static let source: CGFloat = 52
    static let duration: CGFloat = 44
    static let plays: CGFloat = 32
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 10

    private static let albumHiddenBelow: CGFloat = 620

    let title: CGFloat
    let artist: CGFloat
    let album: CGFloat
    let plays: CGFloat

    init(width: CGFloat, showsPlays: Bool = false) {
        let showsAlbum = width >= Self.albumHiddenBelow
        plays = showsPlays ? Self.plays : 0
        let gaps = Self.spacing * ((showsAlbum ? 4 : 3) + (showsPlays ? 1 : 0))
        let flexible = max(0, width - Self.source - plays - Self.duration - gaps)
        title = flexible * (showsAlbum ? 0.46 : 0.62)
        artist = flexible * (showsAlbum ? 0.24 : 0.38)
        album = showsAlbum ? flexible * 0.30 : 0
    }
}

/// 依配置到的寬度分欄。不量測內容也不存狀態，欄寬才不會反過來影響頁面寬度。
/// 子視圖依序為歌名、歌手、專輯、來源、次數、時長
struct TrackColumnLayout: Layout {
    var showsPlays = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = TrackColumns(width: bounds.width, showsPlays: showsPlays)
        let widths = [columns.title, columns.artist, columns.album, TrackColumns.source, columns.plays, TrackColumns.duration]
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            if width > 0 { x += width + TrackColumns.spacing }
        }
    }
}

/// 欄位標題，傳入排序時可以點擊，和 Apple Music 一樣
struct TrackListHeader: View {
    var sort: Binding<TrackSort>?
    var showsPlays = false

    var body: some View {
        TrackColumnLayout(showsPlays: showsPlays) {
            column(String(localized: "field.song", defaultValue: "歌曲"), key: .title, alignment: .leading)
                .padding(.leading, TrackRow.starWidth + TrackRow.artworkSpacing)
            column(String(localized: "field.artist", defaultValue: "歌手"), key: .artist, alignment: .leading)
            column(String(localized: "field.album", defaultValue: "專輯"), key: .album, alignment: .leading).clipped()
            Color.clear
            if showsPlays { column(String(localized: "次數"), key: .plays, alignment: .trailing) }
            else { Color.clear }
            column(String(localized: "時長"), key: .duration, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, TrackColumns.horizontalPadding)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func column(_ title: String, key: TrackSortKey, alignment: Alignment) -> some View {
        if let sort {
            Button {
                sort.wrappedValue = sort.wrappedValue.tapped(key)
            } label: {
                HStack(spacing: 3) {
                    Text(title)
                    if sort.wrappedValue.key == key {
                        Image(systemName: sort.wrappedValue.ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(sort.wrappedValue.key == key ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("依\(title)排序")
        }
        else {
            Text(title)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

/// 播放中的動態圖示，暫停時停在低位
struct PlayingIndicator: View {
    let isAnimating: Bool
    var color: Color = .white

    private static let bars: [(speed: Double, phase: Double)] = [(5.3, 0), (7.1, 1.7), (4.4, 3.1), (6.2, 0.9)]
    private static let maxHeight: CGFloat = 14
    private static let restingHeight: CGFloat = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Self.bars.indices, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: height(of: index, at: time))
                }
            }
            .frame(height: Self.maxHeight, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func height(of index: Int, at time: TimeInterval) -> CGFloat {
        guard isAnimating else { return Self.restingHeight }
        let bar = Self.bars[index]
        // 兩個頻率疊加，看起來才不像固定循環
        let wave = sin(time * bar.speed + bar.phase) * 0.6 + sin(time * bar.speed * 0.37 + bar.phase * 2) * 0.4
        return Self.restingHeight + (Self.maxHeight - Self.restingHeight) * CGFloat((wave + 1) / 2)
    }
}

/// 封面：懸停時顯示播放鍵，點一下就播放；播放中的歌顯示動態圖示
struct TrackArtworkButton: View {
    let source: ArtworkSource
    let side: CGFloat
    let title: String
    let isCurrent: Bool
    let isPlaying: Bool
    let isHovering: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ArtworkView(source: source, side: side)
                if isCurrent || (isHovering && !isDisabled) {
                    RoundedRectangle(cornerRadius: Theme.smallArtworkRadius, style: .continuous)
                        .fill(.black.opacity(0.46))
                    if isHovering {
                        Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    else {
                        PlayingIndicator(isAnimating: isPlaying)
                    }
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(isCurrent ? (isPlaying ? "暫停 \(title)" : "繼續播放 \(title)") : "播放 \(title)")
    }
}

struct TrackRow: View {
    static let starWidth: CGFloat = 12
    static let artworkSpacing: CGFloat = 5

    let row: TrackRowModel
    let isCurrent: Bool
    let isPlaying: Bool
    var isHighlighted = false
    let onPlay: () -> Void
    let onArtwork: () -> Void

    @State private var isHovering = false

    private static let artworkSide: CGFloat = 38

    var body: some View {
        TrackColumnLayout(showsPlays: row.playCount != nil) {
            HStack(spacing: 0) {
                Group {
                    if row.isFavorite {
                        FavoriteStar()
                    }
                    else {
                        Color.clear
                    }
                }
                .frame(width: Self.starWidth)
                .padding(.trailing, Self.artworkSpacing)

                TrackArtworkButton(source: row.artwork, side: Self.artworkSide, title: row.title,
                                   isCurrent: isCurrent, isPlaying: isPlaying, isHovering: isHovering,
                                   isDisabled: row.isDimmed, action: onArtwork)
                    .padding(.trailing, 10)
                Text(row.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(row.artist)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.album)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()

            Group {
                if let quality = row.quality {
                    QualityBadge(rate: quality.rate, bits: quality.bits)
                }
                else if row.isDimmed {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("這首歌目前無法播放")
                }
                else if row.isStreamOnly {
                    Image(systemName: "cloud")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("只有 Apple Music 串流")
                }
                else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)

            // 沒播過的留白，列表才不會滿是 0
            Text(row.playCount.map { $0 > 0 ? String($0) : "" } ?? "")
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(Format.time(row.duration))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .opacity(row.isDimmed ? 0.4 : 1)
        .padding(.horizontal, TrackColumns.horizontalPadding)
        .frame(height: Theme.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundFill)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
    }

    private var backgroundFill: Color {
        if isHighlighted { return Theme.accent.opacity(0.22) }
        if isHovering { return Color.primary.opacity(0.08) }
        return row.index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear
    }
}

/// 可重複使用的列表，每一列的動作由呼叫端提供
struct TrackListView<Menu: View>: View {
    let rows: [TrackRowModel]
    var showsHeader = true
    var sort: Binding<TrackSort>?
    var originalSortTitle = String(localized: "專輯順序")
    var sortKeys = TrackSortKey.selectable
    /// 從別處跳過來時短暫標出的那一列
    var highlightedID: String?
    let onPlay: (TrackRowModel) -> Void
    @ViewBuilder let menu: (TrackRowModel) -> Menu

    @EnvironmentObject private var player: PlaybackCoordinator

    var body: some View {
        VStack(spacing: 4) {
            // 靠右對齊時長欄
            if let sort {
                HStack {
                    Spacer()
                    TrackSortMenu(sort: sort, originalTitle: originalSortTitle, keys: sortKeys)
                }
                .padding(.trailing, TrackColumns.horizontalPadding)
            }
            if showsHeader { TrackListHeader(sort: sort, showsPlays: rows.first?.playCount != nil) }
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    let isCurrent = player.currentItem?.id == row.id
                    TrackRow(row: row, isCurrent: isCurrent, isPlaying: isCurrent && player.status == .playing,
                             isHighlighted: row.id == highlightedID) {
                        onPlay(row)
                    } onArtwork: {
                        // 正在播的歌再點一次是暫停，和 Apple Music 相同
                        if isCurrent { player.togglePause() }
                        else { onPlay(row) }
                    }
                    .contextMenu { menu(row) }
                }
            }
        }
    }
}

/// 頁面上的排序選單，和點欄位標題共用同一個設定
struct TrackSortMenu: View {
    @Binding var sort: TrackSort
    let originalTitle: String
    var keys = TrackSortKey.selectable

    private var label: String {
        sort.key == .original ? originalTitle : sort.key.title
    }

    var body: some View {
        Menu {
            Picker("排序方式", selection: Binding(get: { sort.key }, set: { sort = TrackSort(key: $0, ascending: $0.defaultAscending) })) {
                Text(originalTitle).tag(TrackSortKey.original)
                ForEach(keys) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Picker("順序", selection: $sort.ascending) {
                Text("遞增").tag(true)
                Text("遞減").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PageMenuLabel(title: label, systemImage: "arrow.up.arrow.down")
        }
        .pageMenuStyle()
        .help("排序方式")
        .accessibilityLabel("排序方式")
    }
}
