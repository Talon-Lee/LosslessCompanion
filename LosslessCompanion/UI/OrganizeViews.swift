//
//  OrganizeViews.swift
//  LosslessCompanion
//
//  本地檔案整理：改檔名與套用 Apple Music 資料、合併專輯、打包匯出。
//  都先列出會發生什麼，按下去才動到檔案，做完可以從提示或設定頁復原。
//

import AppKit
import SwiftUI

struct OrganizeSheetRequest: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [LibraryTrack]
}

struct AlbumMergeSheetRequest: Identifiable {
    let id = UUID()
    let album: AlbumGroup
}

struct ExportSheetRequest: Identifiable {
    let id = UUID()
    let title: String
    let albums: [AlbumGroup]
}

/// 專輯右鍵與 ⋯ 選單共用
struct AlbumFileActions: View {
    let album: AlbumGroup

    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("整理檔案…") { navigation.organizeRequest = OrganizeSheetRequest(title: album.title, tracks: album.tracks) }
        Button("合併專輯…") { navigation.mergeRequest = AlbumMergeSheetRequest(album: album) }
        if model.albumMerges.merges.merge(containing: album.id) != nil {
            Button("取消合併") { model.albumMerges.split(target: album.id) }
        }
        Button("輸出打包…") { navigation.exportRequest = ExportSheetRequest(title: album.title, albums: [album]) }
        FolderPlaylistMenu(folder: album.id)
    }
}

/// 列出這個資料夾與上面幾層，例如專輯資料夾、歌手資料夾
struct FolderPlaylistMenu: View {
    let folder: String

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let choices = model.folderChoices(for: folder)
        if choices.count == 1 {
            Button("建立資料夾播放列表") { model.openFolderPlaylist(for: choices[0]) }
        }
        else if choices.count > 1 {
            Menu("建立資料夾播放列表") {
                ForEach(choices, id: \.self) { choice in
                    Button(URL(fileURLWithPath: choice).lastPathComponent) { model.openFolderPlaylist(for: choice) }
                }
            }
        }
    }
}

/// 頁面上的打包鍵，範圍就是這一頁正在顯示的專輯
struct ExportPageButton: View {
    let title: String
    let albums: [AlbumGroup]

    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        Button {
            navigation.exportRequest = ExportSheetRequest(title: title, albums: albums)
        } label: {
            Label("輸出打包", systemImage: "shippingbox")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(albums.isEmpty)
        .help("把這一頁的 \(albums.count) 張專輯打包成 ZIP")
    }
}

private struct SheetHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Music 記的是檔案位置，改名或搬移後它可能會顯示找不到檔案
private struct MusicFileWarning: View {
    let paths: [String]

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let count = model.musicFileCount(in: paths)
        if count > 0 {
            Label("有 \(count) 個檔案也在 Apple Music 資料庫裡，改名或搬移後 Music 可能會找不到它們", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Rename and tags

struct OrganizeSheet: View {
    let request: OrganizeSheetRequest

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var source = OrganizeSource.appleMusic
    @State private var template: FileNameTemplate
    @State private var writesTags = true
    @State private var excluded = Set<String>()
    @State private var editedNames = [String: String]()
    @State private var progress: (done: Int, total: Int)?
    @State private var errorMessage: String?
    @State private var failures = [String]()

    init(request: OrganizeSheetRequest) {
        self.request = request
        _template = State(initialValue: OrganizePlanner.defaultTemplate(for: request.tracks))
    }

    private var matchedCount: Int {
        request.tracks.filter { model.appleEntries[$0.path] != nil }.count
    }

    private var rows: [OrganizeRow] {
        OrganizePlanner.rows(for: request.tracks, apple: model.appleEntries, source: source, template: template)
    }

    private func name(of row: OrganizeRow) -> String {
        editedNames[row.id] ?? row.stem
    }

    private func moves(_ rows: [OrganizeRow]) -> [FileMove] {
        OrganizePlanner.moves(for: rows.filter { !excluded.contains($0.id) }, names: editedNames)
    }

    private func tags(_ rows: [OrganizeRow]) -> [(path: String, update: TagUpdate)] {
        guard writesTags, source == .appleMusic else { return [] }
        return OrganizePlanner.tags(for: rows.filter { !excluded.contains($0.id) })
    }

    var body: some View {
        let rows = self.rows
        let moves = self.moves(rows)
        let tags = self.tags(rows)
        let planError = self.planError(moves)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(title: String(localized: "整理檔案"), subtitle: request.title)
                controls
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            footer(moves: moves, tags: tags, planError: planError)
        }
        .frame(width: 780, height: 620)
        .disabled(progress != nil)
        .onAppear {
            if matchedCount == 0 { source = .fileTags }
            model.refreshMusicFiles()
        }
    }

    private func planError(_ moves: [FileMove]) -> String? {
        if model.isInQueue(Set(request.tracks.map(\.path))) { return OrganizeError.inQueue.errorDescription }
        do {
            _ = try MovePlan(moves: moves)
            return nil
        }
        catch {
            return error.localizedDescription
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("資料來源", selection: $source) {
                ForEach(OrganizeSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(matchedCount == 0)
            Picker("檔名格式", selection: $template) {
                ForEach(FileNameTemplate.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Spacer()
            Text(source == .appleMusic ? "\(matchedCount) / \(request.tracks.count) 首有 Apple Music 資料" : "用檔案標籤組成檔名")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .onChange(of: source) { editedNames = [:] }
        .onChange(of: template) { editedNames = [:] }
    }

    private func rowView(_ row: OrganizeRow, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("套用", isOn: Binding(
                get: { !excluded.contains(row.id) },
                set: { isOn in
                    if isOn { excluded.remove(row.id) }
                    else { excluded.insert(row.id) }
                }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.track.url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 2) {
                    TextField("檔名", text: Binding(get: { name(of: row) }, set: { editedNames[row.id] = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    Text("." + row.track.url.pathExtension)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                if source == .appleMusic, writesTags, !row.changes.isEmpty {
                    Text(row.changes.joined(separator: "　"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(row.changes.joined(separator: "\n"))
                }
            }
            .opacity(excluded.contains(row.id) ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.03) : .clear)
    }

    private func footer(moves: [FileMove], tags: [(path: String, update: TagUpdate)], planError: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if source == .appleMusic {
                Toggle("同時把 Apple Music 的資料寫入檔案標籤", isOn: $writesTags)
                    .font(.system(size: 12.5))
            }
            if let message = errorMessage ?? planError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            MusicFileWarning(paths: moves.map(\.from))
            if !failures.isEmpty {
                ScrollView {
                    Text(failures.joined(separator: "\n"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
            }
            HStack {
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 180)
                }
                else {
                    Text(summary(moves: moves, tags: tags))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(failures.isEmpty ? "取消" : "關閉") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("套用") { apply(moves: moves, tags: tags) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(planError != nil || (moves.isEmpty && tags.isEmpty))
            }
        }
        .padding(16)
    }

    private func summary(moves: [FileMove], tags: [(path: String, update: TagUpdate)]) -> String {
        var parts = [String]()
        if !moves.isEmpty { parts.append(String(localized: "改名 \(moves.count) 個檔案")) }
        if !tags.isEmpty { parts.append(String(localized: "寫入 \(tags.count) 首標籤")) }
        return parts.isEmpty ? String(localized: "沒有需要改動的項目") : parts.joined(separator: String(localized: "，")) + String(localized: "。音訊內容不變，可以復原。")
    }

    private func apply(moves: [FileMove], tags: [(path: String, update: TagUpdate)]) {
        errorMessage = nil
        failures = []
        progress = (0, moves.count + tags.count)
        var request = OrganizeRequest(title: String(localized: "整理《\(request.title)》"))
        request.moves = moves
        request.tags = tags
        model.organize(request, progress: { done, total in progress = (done, total) }) { result in
            progress = nil
            switch result {
            case .success(let outcome):
                if outcome.failures.isEmpty { dismiss() }
                else { failures = outcome.failures }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Merge

struct AlbumMergeSheet: View {
    let request: AlbumMergeSheetRequest

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var movesFiles = false
    @State private var isRunning = false
    @State private var errorMessage: String?

    private static let rowLimit = 80

    init(request: AlbumMergeSheetRequest) {
        self.request = request
        _title = State(initialValue: request.album.title)
    }

    private var candidates: [AlbumGroup] {
        let all = AlbumMergePlanner.candidates(for: request.album, in: model.albums)
        let tokens = SearchText.tokens(of: query)
        guard !tokens.isEmpty else { return Array(all.prefix(Self.rowLimit)) }
        return Array(all.filter { album in
            let key = SearchText.normalize(album.title + "\n" + album.artist + "\n" + album.id)
            return tokens.allSatisfy(key.contains)
        }.prefix(Self.rowLimit))
    }

    private var chosen: [AlbumGroup] {
        model.albums.filter { selected.contains($0.id) }
    }

    private var duplicates: Int {
        AlbumMergePlanner.duplicateCount(in: [request.album] + chosen)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(title: String(localized: "合併專輯"), subtitle: request.album.id)
                LabeledContent("合併後的名稱") {
                    TextField("專輯名稱", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                .font(.system(size: 12.5))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("搜尋專輯、歌手或資料夾", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { album in
                        candidateRow(album)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 600)
        .disabled(isRunning)
        .onAppear { model.refreshMusicFiles() }
    }

    private func candidateRow(_ album: AlbumGroup) -> some View {
        Button {
            if selected.remove(album.id) == nil { selected.insert(album.id) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected.contains(album.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected.contains(album.id) ? Theme.accent : Color.secondary.opacity(0.5))
                ArtworkView(source: .local(album.representative), side: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text("\(album.artist)，\(album.tracks.count) 首，\(URL(fileURLWithPath: album.id).lastPathComponent)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("同時把檔案搬到這張專輯的資料夾", isOn: $movesFiles)
                .font(.system(size: 12.5))
            Text(movesFiles ? "音軌或檔名重複時會放進 Disc 2 這類子資料夾，封面圖留在原處，不會刪除任何檔案。"
                            : "只改變 App 裡的顯示，檔案留在原位，隨時可以取消合併。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if duplicates > 0, !selected.isEmpty {
                Label("有 \(duplicates) 首歌名重複，可能是同一張專輯的另一個版本，合併後會出現兩次", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if movesFiles {
                MusicFileWarning(paths: chosen.flatMap(\.tracks).map(\.path))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("合併 \(selected.count) 張專輯", action: merge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func merge() {
        errorMessage = nil
        isRunning = true
        let name = title.trimmingCharacters(in: .whitespaces)
        model.merge(chosen, into: request.album, title: name == request.album.title ? nil : name, movesFiles: movesFiles) { result in
            isRunning = false
            switch result {
            case .success: dismiss()
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    let request: ExportSheetRequest

    @EnvironmentObject private var playCounts: PlayCountStore
    @Environment(\.dismiss) private var dismiss
    @State private var job: ExportJob?

    var body: some View {
        Group {
            if let job {
                ExportPanel(job: job, request: request) { dismiss() }
            }
            else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .frame(width: 460)
        .task {
            let albums = request.albums
            let records = playCounts.records
            let entries = await Task.detached(priority: .userInitiated) {
                ExportPlanner.entries(for: albums, playCounts: records)
            }.value
            job = ExportJob(entries: entries)
        }
    }
}

private struct ExportPanel: View {
    @ObservedObject var job: ExportJob
    let request: ExportSheetRequest
    let onClose: () -> Void

    private var trackCount: Int {
        request.albums.reduce(0) { $0 + $1.tracks.count }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(job.totalSize), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: String(localized: "輸出打包"), subtitle: request.title)
            Text("\(request.albums.count) 張專輯，\(trackCount) 首歌曲，共 \(size)。音檔不壓縮也不轉檔，封面圖一起打包，並附上播放次數清單。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .running:
            ProgressView(value: job.fraction)
        case .finished(let url):
            Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch job.state {
        case .running:
            Button("取消") { job.cancel() }
                .keyboardShortcut(.cancelAction)
        case .finished(let url):
            Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("完成", action: onClose)
                .keyboardShortcut(.defaultAction)
        case .ready, .failed:
            Button("取消", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("選擇位置並開始", action: start)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func start() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = FileNamer.fileName(stem: request.title, extension: "zip")
        panel.prompt = String(localized: "export.save", defaultValue: "輸出")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.start(destination: url)
    }
}

// MARK: - Notice and history

/// 剛做完的整理，隨時可以一鍵退回去
struct OrganizeBanner: View {
    @EnvironmentObject private var model: AppModel
    @State private var errorMessage: String?

    var body: some View {
        if let record = model.organizeNotice {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text(errorMessage ?? "\(record.title)：\(record.summary)")
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("復原") {
                    model.undo(record) { error in errorMessage = error?.localizedDescription }
                }
                Button {
                    errorMessage = nil
                    model.organizeNotice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("關閉提示")
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))
        }
    }
}

/// 設定頁的整理紀錄，提示關掉之後還能從這裡復原
struct OrganizeHistorySection: View {
    @EnvironmentObject private var organizer: LibraryOrganizer
    @EnvironmentObject private var model: AppModel
    @State private var errorMessage: String?

    var body: some View {
        Section("檔案整理紀錄") {
            if organizer.history.isEmpty {
                Text("還沒有整理過檔案")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(organizer.history) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title)
                            .lineLimit(1)
                        Text("\(record.date.formatted(date: .abbreviated, time: .shortened))，\(record.summary)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("復原") {
                        model.undo(record) { error in errorMessage = error?.localizedDescription }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}
