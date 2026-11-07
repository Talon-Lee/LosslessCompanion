//
//  MatchReviewSheet.swift
//  LosslessCompanion
//
//  逐首校閱：左邊是本地檔案的資料，下面列出 Music 資料庫裡的候選，也可以自己搜尋。
//  每個決定都立刻存檔，隨時可以關掉，下次從還沒決定的曲目繼續。
//

import SwiftUI

struct MatchReviewRequest: Identifiable {
    let id = UUID()
    let tracks: [LibraryTrack]
}

struct MatchReviewSheet: View {
    let request: MatchReviewRequest

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var review: MatchReviewStore
    @Environment(\.dismiss) private var dismiss

    @State private var position = 0
    @State private var query = ""
    @State private var isConfirmingBulkLink = false

    private var track: LibraryTrack { request.tracks[position] }

    /// 這份佇列裡可以一次連結的曲目；已經決定過的不算
    private var certainLinks: [(track: LibraryTrack, entry: MusicPlaylistEntry)] {
        model.certainLinks(in: request.tracks.filter { model.reviewStatus(of: $0) == .unmatched })
    }

    private var candidates: [MatchSuggestion] {
        query.isEmpty ? model.suggester.suggestions(for: track) : model.suggester.search(query, for: track)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            candidateList
            Divider()
            footer
        }
        .frame(width: 680, height: 600)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(source: .local(track), side: 72, radius: Theme.artworkRadius)
            VStack(alignment: .leading, spacing: 3) {
                Text("本地音檔")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(track.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text("\(track.artist) — \(track.album)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(Format.time(track.duration))，\(Format.quality(rate: track.sampleRate, bits: track.bitsPerSample))，\(track.url.lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("第 \(position + 1) / \(request.tracks.count) 首")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜尋 Apple Music 資料庫", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var candidateList: some View {
        let candidates = self.candidates
        if candidates.isEmpty {
            ContentUnavailableView(query.isEmpty ? "沒有相近的歌曲" : "找不到符合的歌曲",
                                   systemImage: "music.note.list",
                                   description: Text(query.isEmpty ? "可以用歌名或歌手搜尋，或標記為僅本地。" : "換個歌名或歌手試試。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { suggestion in
                        CandidateRow(suggestion: suggestion, currentFile: currentFile(for: suggestion)) {
                            review.link(track, to: suggestion.entry)
                            advance()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .id(position)
        }
    }

    private var footer: some View {
        let certain = certainLinks
        return HStack(spacing: 10) {
            Button("僅本地，不再提示") {
                review.markLocalOnly(track)
                advance()
            }
            if !certain.isEmpty {
                Button("連結全部相符（\(certain.count) 首）") { isConfirmingBulkLink = true }
                    .confirmationDialog("一次連結 \(certain.count) 首？", isPresented: $isConfirmingBulkLink) {
                        Button("全部連結") {
                            review.link(certain)
                            dismiss()
                        }
                    } message: {
                        Text("這些曲目的歌名、歌手、專輯與長度都和 Apple Music 的歌曲相符。之後可以在「已校閱」逐一復原。")
                    }
            }
            Spacer()
            Button("上一首") { move(to: position - 1) }
                .disabled(position == 0)
            Button("略過") { advance() }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.regular)
        .padding(14)
    }

    /// 這首歌已經對應到別的檔案時要先講清楚，連結後會換掉
    private func currentFile(for suggestion: MatchSuggestion) -> String? {
        guard let match = model.match(for: suggestion.entry), match.track.path != track.path else { return nil }
        return match.track.url.lastPathComponent
    }

    private func advance() {
        if position + 1 < request.tracks.count {
            move(to: position + 1)
        }
        else {
            dismiss()
        }
    }

    private func move(to newPosition: Int) {
        position = newPosition
        query = ""
    }
}

private struct CandidateRow: View {
    let suggestion: MatchSuggestion
    let currentFile: String?
    let onLink: () -> Void

    @State private var isHovering = false

    private var entry: MusicPlaylistEntry { suggestion.entry }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: .musicLibrary(trackID: entry.trackID), side: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if suggestion.isLikely {
                        Text("很可能")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.primary.opacity(0.42), lineWidth: 0.7)
                            }
                    }
                }
                Text("\(entry.artist) — \(entry.album)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !suggestion.reasons.isEmpty {
                    Text(suggestion.reasons.joined(separator: String(localized: "、")))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let currentFile {
                    Text("目前對應 \(currentFile)，連結後改用這個檔案")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(Format.time(entry.duration))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("連結", action: onLink)
                .accessibilityLabel("連結到 \(entry.title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        }
        .onHover { isHovering = $0 }
    }
}
