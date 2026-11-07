//
//  FileOrganizer.swift
//  LosslessCompanion
//
//  改名、搬移與寫入標籤。這裡不會刪除也不會覆蓋任何音檔：目的地已有檔案就整批取消。
//  每次操作留下紀錄，可以完整復原；程式中途結束時，下次啟動從日誌接著做完，連結才不會斷掉。
//

import Combine
import Darwin
import Foundation

struct FileMove: Codable, Hashable {
    let from: String
    let to: String

    var reversed: FileMove { FileMove(from: to, to: from) }
}

// MARK: - Names

enum FileNamer {
    private static let maxNameBytes = 255
    private static let replacements: [Character: Character] = [
        "/": "／", "\\": "＼", ":": "：", "*": "＊", "?": "？", "\"": "＂", "<": "＜", ">": "＞", "|": "｜"
    ]

    /// 全形字元看起來一樣，換到其他系統也合法；Finder 會把冒號顯示成斜線，所以一起換掉
    static func sanitized(_ name: String) -> String {
        var text = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        text = String(text.map { replacements[$0] ?? $0 })
        text = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") || text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    /// 檔案系統的上限是位元組，日文歌名很容易超過，要在字元邊界截斷
    static func fileName(stem: String, extension fileExtension: String) -> String {
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        var name = sanitized(stem)
        while name.utf8.count + suffix.utf8.count > maxNameBytes { name.removeLast() }
        return name + suffix
    }

    /// APFS 預設不分大小寫，也不分 Unicode 正規形式，這樣比較才知道兩個名稱是不是同一個檔案
    static func identity(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

enum FileNameTemplate: String, CaseIterable, Identifiable {
    case trackTitle, discTrackTitle, trackArtistTitle, artistTitle, title, unchanged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trackTitle: return String(localized: "01 歌名")
        case .discTrackTitle: return String(localized: "1-01 歌名")
        case .trackArtistTitle: return String(localized: "01 歌手 - 歌名")
        case .artistTitle: return String(localized: "歌手 - 歌名")
        case .title: return String(localized: "歌名")
        case .unchanged: return String(localized: "保留原檔名")
        }
    }

    /// 沒有音軌號碼時不放數字，也不留多餘的空格
    func stem(of track: LibraryTrack, title: String, artist: String, number: Int, disc: Int) -> String {
        let padded = number > 0 ? String(format: "%02d", number) : ""
        switch self {
        case .trackTitle:
            return [padded, title].filter { !$0.isEmpty }.joined(separator: " ")
        case .discTrackTitle:
            let position = number > 0 ? "\(max(disc, 1))-\(padded)" : ""
            return [position, title].filter { !$0.isEmpty }.joined(separator: " ")
        case .trackArtistTitle:
            return [padded, [artist, title].filter { !$0.isEmpty }.joined(separator: " - ")].filter { !$0.isEmpty }.joined(separator: " ")
        case .artistTitle:
            return [artist, title].filter { !$0.isEmpty }.joined(separator: " - ")
        case .title:
            return title
        case .unchanged:
            return track.url.deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - Planning

enum OrganizeError: LocalizedError, Equatable {
    case missing(String)
    case destinationExists(String)
    case duplicateDestination(String)
    case invalidName
    case inQueue
    case undoConflict(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): return String(localized: "找不到「\(name)」，可能已被移走")
        case .destinationExists(let name): return String(localized: "「\(name)」已經存在，不會覆蓋")
        case .duplicateDestination(let name): return String(localized: "有兩個檔案都要改成「\(name)」")
        case .invalidName: return String(localized: "檔名不能是空白")
        case .inQueue: return String(localized: "這些檔案在目前的佇列裡，請先停止播放")
        case .undoConflict(let name): return String(localized: "「\(name)」已經不在當時的位置，無法復原")
        }
    }
}

/// 檔名交換或只改大小寫時，目的地就是另一個來源，要先搬到暫存名稱，否則會互相擋住
struct MovePlan: Codable, Equatable {
    let moves: [FileMove]
    let steps: [FileMove]

    init(moves: [FileMove], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         temporaryName: () -> String = { ".lc-moving-\(UUID().uuidString)" }) throws {
        let moves = moves.filter { $0.from != $0.to }
        var destinations = Set<String>()
        let sources = Set(moves.map { FileNamer.identity($0.from) })
        for move in moves {
            let name = URL(fileURLWithPath: move.to).lastPathComponent
            guard !name.isEmpty, name != "." else { throw OrganizeError.invalidName }
            guard exists(move.from) else { throw OrganizeError.missing(URL(fileURLWithPath: move.from).lastPathComponent) }
            let identity = FileNamer.identity(move.to)
            guard destinations.insert(identity).inserted else { throw OrganizeError.duplicateDestination(name) }
            guard sources.contains(identity) || !exists(move.to) else { throw OrganizeError.destinationExists(name) }
        }

        var direct = [FileMove]()
        var before = [FileMove]()
        var after = [FileMove]()
        for move in moves {
            guard sources.contains(FileNamer.identity(move.to)) else {
                direct.append(move)
                continue
            }
            let target = URL(fileURLWithPath: move.to)
            let name = target.pathExtension.isEmpty ? temporaryName() : temporaryName() + "." + target.pathExtension
            let parking = target.deletingLastPathComponent().appendingPathComponent(name).path
            before.append(FileMove(from: move.from, to: parking))
            after.append(FileMove(from: parking, to: move.to))
        }
        self.moves = moves
        steps = before + direct + after
    }
}

// MARK: - Records

struct TagRestorePoint: Codable, Equatable {
    /// 寫入標籤時的路徑，也就是改名之前的路徑
    let path: String
    /// 歷史資料夾裡的檔名；nil 代表原本沒有標籤
    let snapshot: String?
}

struct OrganizeRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    var moves: [FileMove]
    var tags: [TagRestorePoint]
    /// 這次操作合併的專輯與併進去的資料夾，復原時一起拆開
    var mergedAlbum: String?
    var mergedFolders: [String]?

    var summary: String {
        var parts = [String]()
        if !moves.isEmpty { parts.append(String(localized: "改名或搬移 \(moves.count) 個檔案")) }
        if !tags.isEmpty { parts.append(String(localized: "寫入 \(tags.count) 首標籤")) }
        if mergedAlbum != nil, parts.isEmpty { parts.append(String(localized: "合併專輯")) }
        return parts.joined(separator: String(localized: "，"))
    }
}

struct OrganizeRequest {
    let title: String
    var moves = [FileMove]()
    var tags = [(path: String, update: TagUpdate)]()
    var mergedAlbum: String?
    var mergedFolders: [String]?
}

struct OrganizeOutcome {
    let record: OrganizeRecord
    /// 個別檔案失敗時其他檔案照常完成，每一筆的格式是「檔名：原因」
    let failures: [String]
}

final class LibraryOrganizer: ObservableObject {
    @Published private(set) var history = [OrganizeRecord]()

    private static let historyLimit = 30

    private let historyURL: URL
    private let snapshotsURL: URL
    private let journalURL: URL

    init(directory: URL = AppPaths.support) {
        historyURL = directory.appendingPathComponent("organize-history-v1.json")
        snapshotsURL = directory.appendingPathComponent("organize-snapshots", isDirectory: true)
        journalURL = directory.appendingPathComponent("organize-journal-v1.json")
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([OrganizeRecord].self, from: data) {
            history = saved
        }
    }

    // MARK: Running

    /// 在背景執行。搬移的計畫先驗證，有問題時什麼都不會改動
    func run(_ request: OrganizeRequest, progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> OrganizeOutcome {
        let plan = try MovePlan(moves: request.moves)
        let id = UUID()
        let total = request.tags.count + plan.steps.count
        var completed = 0
        var failures = [String]()
        var points = [TagRestorePoint]()

        for (index, item) in request.tags.enumerated() {
            let url = URL(fileURLWithPath: item.path)
            do {
                let old = try TagWriter.apply(item.update, to: url)
                points.append(TagRestorePoint(path: item.path, snapshot: try store(old, record: id, index: index)))
            }
            catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
            completed += 1
            progress(completed, total)
        }

        do {
            try execute(plan) {
                completed += 1
                progress(completed, total)
            }
        }
        catch {
            // 標籤已經寫了但檔名沒改成，這樣的半成品不好理解，一起退回去
            for point in points { try? restore(point, record: id) }
            removeSnapshots(of: id)
            throw error
        }

        let record = OrganizeRecord(id: id, date: Date(), title: request.title, moves: plan.moves, tags: points,
                                    mergedAlbum: request.mergedAlbum, mergedFolders: request.mergedFolders)
        return OrganizeOutcome(record: record, failures: failures)
    }

    /// 在背景執行。復原成功後由 finish(undoing:) 移除紀錄
    func undo(_ record: OrganizeRecord, progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> [String] {
        let plan: MovePlan
        do {
            plan = try MovePlan(moves: record.moves.reversed().map(\.reversed))
        }
        catch OrganizeError.missing(let name) {
            throw OrganizeError.undoConflict(name)
        }
        let total = plan.steps.count + record.tags.count
        var completed = 0
        try execute(plan) {
            completed += 1
            progress(completed, total)
        }

        var failures = [String]()
        for point in record.tags {
            do {
                try restore(point, record: record.id)
            }
            catch {
                failures.append("\(URL(fileURLWithPath: point.path).lastPathComponent)：\(error.localizedDescription)")
            }
            completed += 1
            progress(completed, total)
        }
        return failures
    }

    /// 回到主執行緒後，索引與連結都更新好才清掉日誌
    func finish(_ record: OrganizeRecord) {
        history.insert(record, at: 0)
        for old in history.dropFirst(Self.historyLimit) { removeSnapshots(of: old.id) }
        history = Array(history.prefix(Self.historyLimit))
        saveHistory()
        clearJournal()
    }

    func finish(undoing record: OrganizeRecord) {
        history.removeAll { $0.id == record.id }
        removeSnapshots(of: record.id)
        saveHistory()
        clearJournal()
    }

    /// 上次執行到一半就結束時把剩下的步驟做完，回傳要套用到索引的搬移
    func recover() -> [FileMove] {
        guard let data = try? Data(contentsOf: journalURL), let plan = try? JSONDecoder().decode(MovePlan.self, from: data) else { return [] }
        for step in plan.steps where FileManager.default.fileExists(atPath: step.from) && !FileManager.default.fileExists(atPath: step.to) {
            try? Self.rename(step)
        }
        clearJournal()
        return plan.moves.filter { FileManager.default.fileExists(atPath: $0.to) }
    }

    // MARK: Private

    private func execute(_ plan: MovePlan, onStep: () -> Void) throws {
        guard !plan.steps.isEmpty else { return }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: journalURL, options: .atomic)

        var done = [FileMove]()
        do {
            for step in plan.steps {
                try Self.rename(step)
                done.append(step)
                onStep()
            }
        }
        catch {
            for step in done.reversed() { try? Self.rename(step.reversed) }
            clearJournal()
            throw error
        }
    }

    /// RENAME_EXCL 由檔案系統保證不覆蓋，檢查和搬移之間多出來的檔案也不會被蓋掉
    private static func rename(_ move: FileMove) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: move.to).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if renamex_np(move.from, move.to, UInt32(RENAME_EXCL)) == 0 { return }
        // 跨磁碟不能直接改名，這時由系統複製再移除；它同樣不會覆蓋
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try FileManager.default.moveItem(atPath: move.from, toPath: move.to)
    }

    private func store(_ snapshot: Data?, record: UUID, index: Int) throws -> String? {
        guard let snapshot else { return nil }
        let directory = snapshotsURL.appendingPathComponent(record.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(index).tag"
        try snapshot.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    private func restore(_ point: TagRestorePoint, record: UUID) throws {
        let snapshot = try point.snapshot.map {
            try Data(contentsOf: snapshotsURL.appendingPathComponent(record.uuidString).appendingPathComponent($0))
        }
        try TagWriter.restore(snapshot, to: URL(fileURLWithPath: point.path))
    }

    private func removeSnapshots(of record: UUID) {
        try? FileManager.default.removeItem(at: snapshotsURL.appendingPathComponent(record.uuidString))
    }

    private func clearJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }
}

// MARK: - Rows

enum OrganizeSource: String, CaseIterable, Identifiable {
    case appleMusic, fileTags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .fileTags: return String(localized: "檔案標籤")
        }
    }
}

struct OrganizeRow: Identifiable, Equatable {
    let track: LibraryTrack
    let usesAppleMusic: Bool
    /// 不含副檔名的新檔名
    let stem: String
    let update: TagUpdate
    /// 給使用者看的差異，例如「歌名：A → B」
    let changes: [String]

    var id: String { track.path }
}

enum OrganizePlanner {
    static func rows(for tracks: [LibraryTrack], apple: [String: MusicPlaylistEntry], source: OrganizeSource,
                     template: FileNameTemplate) -> [OrganizeRow] {
        tracks.map { track in
            let entry = source == .appleMusic ? apple[track.path] : nil
            let update = entry.map { self.update(for: track, from: $0) } ?? TagUpdate()
            let title = entry?.title ?? track.title
            let artist = entry?.artist ?? track.artist
            let number = entry.flatMap { $0.trackNumber > 0 ? $0.trackNumber : nil } ?? track.trackNumber
            let disc = entry.flatMap { $0.discNumber > 0 ? $0.discNumber : nil } ?? track.discNumber
            return OrganizeRow(track: track, usesAppleMusic: entry != nil,
                               stem: template.stem(of: track, title: title, artist: artist, number: number, disc: disc),
                               update: update, changes: changes(for: track, update: update))
        }
    }

    /// names 是使用者改過的檔名，不含副檔名；檔名沒變的不算
    static func moves(for rows: [OrganizeRow], names: [String: String] = [:]) -> [FileMove] {
        rows.compactMap { row in
            let track = row.track
            let name = FileNamer.fileName(stem: names[row.id] ?? row.stem, extension: track.url.pathExtension)
            let target = track.url.deletingLastPathComponent().appendingPathComponent(name).path
            return target == track.path ? nil : FileMove(from: track.path, to: target)
        }
    }

    static func tags(for rows: [OrganizeRow]) -> [(path: String, update: TagUpdate)] {
        rows.filter { !$0.update.isEmpty && TagWriter.supports($0.track.url) }.map { ($0.track.path, $0.update) }
    }

    /// 多張碟的專輯預設把碟號放進檔名，不同碟的同一軌才不會排在一起
    static func defaultTemplate(for tracks: [LibraryTrack]) -> FileNameTemplate {
        Set(tracks.map { max($0.discNumber, 1) }).count > 1 ? .discTrackTitle : .trackTitle
    }

    /// 只寫真的不同的欄位。Music 沒有的資料不會把檔案裡的清掉
    static func update(for track: LibraryTrack, from entry: MusicPlaylistEntry) -> TagUpdate {
        var update = TagUpdate()
        if !entry.title.isEmpty, entry.title != track.title { update.title = entry.title }
        if !entry.artist.isEmpty, entry.artist != track.artist { update.artist = entry.artist }
        if !entry.albumArtist.isEmpty, entry.albumArtist != track.albumArtist { update.albumArtist = entry.albumArtist }
        // 只差「 - Single」這類後綴時不算不同，那是 Music 型錄的寫法，不是專輯名稱
        if !entry.album.isEmpty, TrackMatcher.albumKey(entry.album) != TrackMatcher.albumKey(track.album) { update.album = entry.album }
        if entry.trackNumber > 0, entry.trackNumber != track.trackNumber { update.trackNumber = entry.trackNumber }
        // 單碟專輯的檔案常常沒有碟號，Music 回報的 1 沒有資訊量
        if entry.discNumber > 1 || (entry.discNumber == 1 && track.discNumber > 1) { update.discNumber = entry.discNumber }
        if let genre = entry.genre, !genre.isEmpty, GenreName.canonical(genre) != GenreName.canonical(track.genre) { update.genre = genre }
        if let composer = entry.composer, !composer.isEmpty, composer != track.composer { update.composer = composer }
        if entry.year > 0, entry.year != track.year { update.year = entry.year }
        if update.discNumber == track.discNumber { update.discNumber = nil }
        return update
    }

    private static func changes(for track: LibraryTrack, update: TagUpdate) -> [String] {
        var changes = [String]()
        func add(_ name: String, _ old: String, _ new: String?) {
            if let new { changes.append(old.isEmpty ? "\(name)：\(new)" : "\(name)：\(old) → \(new)") }
        }
        add(String(localized: "歌名"), track.title, update.title)
        add(String(localized: "field.artist", defaultValue: "歌手"), track.artist, update.artist)
        add(String(localized: "專輯歌手"), track.albumArtist ?? "", update.albumArtist)
        add(String(localized: "field.album", defaultValue: "專輯"), track.album, update.album)
        add(String(localized: "音軌"), track.trackNumber > 0 ? String(track.trackNumber) : "", update.trackNumber.map(String.init))
        add(String(localized: "碟號"), track.discNumber > 0 ? String(track.discNumber) : "", update.discNumber.map(String.init))
        add(String(localized: "field.genre", defaultValue: "類型"), track.genre ?? "", update.genre)
        add(String(localized: "field.composer", defaultValue: "作曲者"), track.composer ?? "", update.composer)
        add(String(localized: "年份"), track.year.map(String.init) ?? "", update.year.map(String.init))
        return changes
    }
}
