//
//  Inbox.swift
//  LosslessCompanion
//
//  資料庫根資料夾裡的「收件匣」：放進去的歌會
//  1. ALAC 的 m4a 轉成 FLAC，逐樣本比對一致後原檔移到垃圾桶
//  2. 依 Music 資料庫或 Apple Music 目錄補齊標籤
//  3. 依現有的歌手資料夾或類型搬到對應的類別
//  有把握的直接歸檔，不確定的留在收件匣等使用者確認。歸檔走整理紀錄，可以復原。
//

import Foundation

final class InboxModel: ObservableObject {
    static let folderName = "收件匣"
    static let audioExtensions: Set<String> = ["m4a", "flac", "wav", "wave", "aif", "aiff", "aifc"]
    private static let pollInterval: TimeInterval = 5
    /// 下載或複製中的檔案大小還在變，停下來一段時間才處理
    private static let settleTime: TimeInterval = 3
    private static let logLimit = 100

    struct Item: Identifiable, Codable, Equatable {
        enum Status: Codable, Equatable {
            case waiting
            case working(String)
            case review
            case failed(String)
        }

        var id: String { path }
        var path: String
        var status: Status
        var plan: InboxPlan?
        /// 例如「已轉成 FLAC，和原檔逐樣本相同」
        var note: String?
        var size: Int64
        var modified: Double

        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var fileExtension: String { URL(fileURLWithPath: path).pathExtension }
    }

    struct LogEntry: Identifiable, Codable, Equatable {
        let id: UUID
        let date: Date
        let name: String
        let destination: String
        let note: String?
    }

    private struct Saved: Codable {
        var items: [Item]
        var log: [LogEntry]
        var held: [String]
    }

    @Published private(set) var items = [Item]()
    @Published private(set) var log = [LogEntry]()
    @Published private(set) var isWorking = false

    /// 由 AppModel 提供：資料庫現有的歌、Music 資料庫、整理檔案
    var libraryTracks: () -> [LibraryTrack] = { [] }
    var musicLibrary: () -> [MusicPlaylistEntry] = { [] }
    var isMusicLibraryReady: () -> Bool = { true }
    var organize: (OrganizeRequest, @escaping (Result<OrganizeOutcome, Error>) -> Void) -> Void = { _, completion in
        completion(.failure(OrganizeError.invalidName))
    }

    /// 原檔轉好之後移到垃圾桶；測試時直接刪掉
    var discardOriginal: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    private let stateURL: URL
    private let rootPath: () -> String?
    private let isEnabled: () -> Bool
    private let queue = DispatchQueue(label: "LosslessCompanion.Inbox", qos: .utility)
    private var timer: Timer?
    private var observed = [String: (size: Int64, modified: Double)]()
    /// 從整理紀錄復原回來的檔案，要使用者確認才歸檔
    private var held = Set<String>()
    private let launched = Date()

    init(stateURL: URL = AppPaths.support.appendingPathComponent("inbox-v1.json"),
         rootPath: @escaping () -> String? = { AppSettings.shared.libraryFolders.first },
         isEnabled: @escaping () -> Bool = { AppSettings.shared.processesInbox }) {
        self.stateURL = stateURL
        self.rootPath = rootPath
        self.isEnabled = isEnabled
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            // 上次結束時正在處理的檔案，這次重新開始
            items = saved.items.filter {
                if case .review = $0.status { return true }
                if case .failed = $0.status { return true }
                return false
            }
            log = saved.log
            held = Set(saved.held)
        }
    }

    var root: URL? { rootPath().map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var folder: URL? { root?.appendingPathComponent(Self.folderName, isDirectory: true) }

    var reviewCount: Int {
        items.filter {
            if case .review = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }.count
    }

    // MARK: Watching

    func start() {
        ensureFolder()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func ensureFolder() -> Bool {
        guard let root, let folder, FileManager.default.fileExists(atPath: root.path) else { return false }
        if FileManager.default.fileExists(atPath: folder.path) { return true }
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil
    }

    /// 立即處理：不必等檔案靜止兩輪，也包含先前失敗的檔案
    func processNow() {
        for index in items.indices {
            if case .failed = items[index].status { items[index].status = .waiting }
        }
        poll(force: true)
    }

    func poll(force: Bool = false) {
        guard isEnabled() || force, !isWorking, let folder, ensureFolder() else { return }
        // 剛開啟時 Music 資料庫可能還沒讀進來，先等一下，免得每首都去查網路
        guard force || isMusicLibraryReady() || Date().timeIntervalSince(launched) > 60 else { return }

        let files = Self.audioFiles(in: folder)
        let present = Set(files.map(\.url.path))
        let before = items.count
        items.removeAll { !present.contains($0.path) }
        held = held.filter(present.contains)
        observed = observed.filter { present.contains($0.key) }

        var ready = [URL]()
        let now = Date().timeIntervalSince1970
        for file in files {
            let path = file.url.path
            let stats = (size: file.size, modified: file.modified)
            if let item = items.first(where: { $0.path == path }), item.size == stats.size, item.modified == stats.modified {
                // 等待確認或失敗的檔案沒有變動就不重做；強制處理時只重做失敗的
                switch item.status {
                case .review, .working: continue
                case .failed: if !force { continue }
                case .waiting: break
                }
            }
            let settled = observed[path].map { $0 == stats } ?? false
            observed[path] = stats
            if force || (settled && now - stats.modified >= Self.settleTime) { ready.append(file.url) }
        }
        if items.count != before { save() }
        guard !ready.isEmpty else { return }
        process(ready)
    }

    static func audioFiles(in folder: URL) -> [(url: URL, size: Int64, modified: Double)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files = [(url: URL, size: Int64, modified: Double)]()
        for case let url as URL in walker where audioExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    // MARK: Processing

    private func process(_ urls: [URL]) {
        isWorking = true
        for url in urls { update(url.path) { $0.status = .waiting } }
        let tracks = libraryTracks()
        let entries = musicLibrary()
        let held = self.held
        guard let root else {
            isWorking = false
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var prepared = [(url: URL, track: LibraryTrack, note: String?)]()
            for url in urls {
                do {
                    let result = try self.prepare(url)
                    prepared.append(result)
                }
                catch {
                    self.onMain { $0.update(url.path) { $0.status = .failed(error.localizedDescription) } }
                }
            }

            self.onMain { model in
                for item in prepared { model.update(item.url.path) { $0.status = .working(String(localized: "比對 Apple Music")) } }
            }
            let matches = InboxLookup.matchLibrary(prepared.map(\.track), entries: entries)
            let layout = InboxLayout.scan(root: root, inboxName: Self.folderName, tracks: tracks)

            var plans = [(url: URL, plan: InboxPlan, note: String?)]()
            for item in prepared {
                var fileMetadata = InboxMetadata(tags: TrackMetadata.tags(for: item.url))
                // 沒有專輯標籤時會拿資料夾名稱當專輯，直接放在收件匣裡的歌不能變成專輯「收件匣」
                if item.url.deletingLastPathComponent().lastPathComponent == Self.folderName { fileMetadata.album = "" }
                let lookup: InboxLookupResult? = matches[item.track.path].map { InboxLookupResult(entry: $0, source: .musicLibrary, artworkURL: nil) }
                    ?? InboxLookup.searchCatalog(for: item.track)
                let metadata = lookup.map { InboxMetadata(entry: $0.entry, fallback: fileMetadata) } ?? fileMetadata
                var plan = InboxPlanner.plan(metadata: metadata, source: lookup?.source ?? .fileTags,
                                             fileExtension: item.url.pathExtension, layout: layout, artworkURL: lookup?.artworkURL)
                if held.contains(item.url.path) { plan.concerns.append(String(localized: "從整理紀錄復原回來的，確認後才會歸檔")) }
                plans.append((item.url, plan, item.note))
            }

            // 同一批裡兩首歌要放到同一個位置時，都留給使用者決定
            var counts = [String: Int]()
            for item in plans { if let destination = item.plan.destination(root: root) { counts[FileNamer.identity(destination.path), default: 0] += 1 } }
            for index in plans.indices {
                if let destination = plans[index].plan.destination(root: root), counts[FileNamer.identity(destination.path)] ?? 0 > 1 {
                    plans[index].plan.concerns.append(String(localized: "和收件匣裡另一首歌的目的地相同"))
                }
            }

            self.onMain { model in
                var confident = [Item]()
                for item in plans {
                    let stats = Self.stats(of: item.url)
                    let entry = Item(path: item.url.path, status: item.plan.isConfident ? .working(String(localized: "歸檔中")) : .review,
                                     plan: item.plan, note: item.note, size: stats.size, modified: stats.modified)
                    model.replace(entry)
                    if item.plan.isConfident { confident.append(entry) }
                }
                model.save()
                model.file(confident) {
                    model.isWorking = false
                    model.poll()
                }
            }
        }
    }

    /// 轉檔並讀出比對用的資料。回傳的網址是轉檔後的檔案
    private func prepare(_ source: URL) throws -> (url: URL, track: LibraryTrack, note: String?) {
        var url = source
        var note: String?
        switch InboxConverter.codec(of: source) {
        case .alac:
            onMain { $0.update(source.path) { $0.status = .working(String(localized: "轉成 FLAC")) } }
            let target = Self.available(source.deletingPathExtension().appendingPathExtension("flac"))
            let working = source.deletingLastPathComponent().appendingPathComponent(".lc-converting-\(UUID().uuidString).flac")
            try InboxConverter.convertALAC(source, to: working)
            do {
                try FileManager.default.moveItem(at: working, to: target)
                try discardOriginal(source)
            }
            catch {
                try? FileManager.default.removeItem(at: working)
                throw error
            }
            url = target
            note = String(localized: "已從 ALAC 轉成 FLAC，和原檔逐樣本相同；原檔在垃圾桶")
            onMain { model in
                model.items.removeAll { $0.path == source.path }
                model.update(target.path) { $0.status = .working(String(localized: "比對 Apple Music")) }
            }
        case .lossy(let codec):
            note = String(localized: "\(codec) 是有損格式，轉成 FLAC 音質也不會變好，維持原格式")
        case .flac, .pcm:
            break
        case .unknown:
            throw InboxConvertError.encoderFailed(String(localized: "無法辨識的音訊格式"))
        }
        return (url, Self.matchingTrack(for: url), note)
    }

    /// 比對只需要標籤與長度；AAC 不能用 LibraryInspector 解碼，所以自己組
    static func matchingTrack(for url: URL) -> LibraryTrack {
        var tags = TrackMetadata.tags(for: url)
        if url.deletingLastPathComponent().lastPathComponent == folderName { tags.album = "" }
        let rate = 44100.0
        return LibraryTrack(path: url.path, title: tags.title, artist: "", album: tags.album, trackNumber: tags.trackNumber,
                            discNumber: 0, sampleRate: rate, bitsPerSample: 16,
                            frameCount: Int64(InboxConverter.duration(of: url) * rate),
                            titleKey: SearchText.normalize(tags.title), artistKey: "", searchKey: "").updating(with: tags)
    }

    private static func available(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        for number in 2... {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(stem) (\(number))").appendingPathExtension(url.pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private static func stats(of url: URL) -> (size: Int64, modified: Double) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? 0), values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    // MARK: Filing

    /// 使用者在收件匣頁面確認或修改後歸檔
    func confirm(_ item: Item, plan: InboxPlan) {
        guard !isWorking else { return }
        var confirmed = item
        confirmed.plan = plan
        confirmed.status = .working(String(localized: "歸檔中"))
        held.remove(item.path)
        replace(confirmed)
        isWorking = true
        file([confirmed]) { [weak self] in
            self?.isWorking = false
            self?.poll()
        }
    }

    /// 重新比對：例如剛把歌加進 Music 資料庫
    func retry(_ item: Item) {
        guard !isWorking else { return }
        update(item.path) { $0.status = .waiting }
        process([URL(fileURLWithPath: item.path)])
    }

    func layout() -> InboxLayout? {
        root.map { InboxLayout.scan(root: $0, inboxName: Self.folderName, tracks: libraryTracks()) }
    }

    private func file(_ entries: [Item], completion: @escaping () -> Void) {
        guard let root, !entries.isEmpty else {
            completion()
            return
        }
        var request = OrganizeRequest(title: entries.count == 1
                                      ? String(localized: "收件匣：\(entries[0].plan?.metadata.title ?? entries[0].name)")
                                      : String(localized: "收件匣：\(entries.count) 首"))
        request.fromInbox = true
        var destinations = [String: URL]()
        for entry in entries {
            guard let plan = entry.plan, let destination = plan.destination(root: root) else { continue }
            let url = URL(fileURLWithPath: entry.path)
            if TagWriter.supports(url) { request.tags.append((entry.path, plan.metadata.tagUpdate)) }
            request.moves.append(FileMove(from: entry.path, to: destination.path))
            destinations[entry.path] = destination
        }

        organize(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let outcome):
                for entry in entries {
                    guard let destination = destinations[entry.path] else { continue }
                    let failure = outcome.failures.first { $0.hasPrefix(URL(fileURLWithPath: entry.path).lastPathComponent + "：") }
                    let note = [entry.note, failure].compactMap { $0 }.joined(separator: "\n")
                    self.log.insert(LogEntry(id: UUID(), date: Date(), name: entry.plan?.metadata.title ?? entry.name,
                                             destination: entry.plan?.relativeDestination ?? destination.path,
                                             note: note.isEmpty ? nil : note), at: 0)
                    self.items.removeAll { $0.path == entry.path }
                    if let artwork = entry.plan?.artworkURL { Self.saveArtworkIfMissing(from: artwork, next: destination) }
                }
                self.log = Array(self.log.prefix(Self.logLimit))
                if let folder = self.folder { Self.removeEmptyFolders(in: folder) }
            case .failure(let error):
                for entry in entries {
                    self.update(entry.path) {
                        $0.status = .review
                        $0.plan?.concerns.append(error.localizedDescription)
                    }
                }
            }
            self.save()
            completion()
        }
    }

    /// 檔案和資料夾都沒有封面時，下載 Apple Music 目錄的封面存成 cover.jpg
    private static func saveArtworkIfMissing(from address: String, next destination: URL) {
        guard let url = URL(string: address) else { return }
        let folder = destination.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            guard TrackArtwork.embedded(in: destination) == nil else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            guard !names.contains(where: { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }) else { return }
            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data, FLACMetadataWriter.mimeType(of: data) == "image/jpeg" else { return }
                try? data.write(to: folder.appendingPathComponent("cover.jpg"), options: .withoutOverwriting)
            }.resume()
        }
    }

    /// 整個資料夾放進收件匣時，歸檔後留下的空資料夾一併清掉；還有其他檔案（例如封面）就留著
    static func removeEmptyFolders(in folder: URL) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var directories = [URL]()
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            directories.append(url)
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
            guard names.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 復原收件匣的整理紀錄後，檔案回到收件匣，改成等使用者確認
    func hold(_ paths: [String]) {
        held.formUnion(paths)
        save()
        poll(force: false)
    }

    #if DEBUG
    /// 截圖用的範例：一首等待確認、一首剛歸檔
    func injectPreview() {
        var metadata = InboxMetadata()
        metadata.title = "Midnight Parade"
        metadata.artist = "9Lana"
        metadata.album = "Midnight Parade"
        metadata.trackNumber = 1
        let plan = InboxPlan(metadata: metadata, source: .fileTags, category: "JPOP", artistFolder: "9LANA",
                             albumFolder: "9Lana - Midnight Parade", fileName: "01 - Midnight Parade.flac", artworkURL: nil,
                             concerns: [String(localized: "Apple Music 找不到這首歌，標籤來自檔案本身")])
        items = [Item(path: (folder?.path ?? "/") + "/Midnight Parade.flac", status: .review, plan: plan,
                      note: String(localized: "已從 ALAC 轉成 FLAC，和原檔逐樣本相同；原檔在垃圾桶"), size: 0, modified: 0)]
        log = [LogEntry(id: UUID(), date: Date().addingTimeInterval(-300), name: "蝸旋 (feat. Ado)",
                        destination: "JPOP/Jon-Yakitory/Jon-Yakitory - 蝸旋 (feat. Ado) (2021)/01 - 蝸旋 (feat. Ado).flac",
                        note: String(localized: "已從 ALAC 轉成 FLAC，和原檔逐樣本相同；原檔在垃圾桶"))]
    }
    #endif

    // MARK: State

    private func onMain(_ body: @escaping (InboxModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    private func update(_ path: String, _ change: (inout Item) -> Void) {
        if let index = items.firstIndex(where: { $0.path == path }) {
            change(&items[index])
        }
        else {
            let stats = Self.stats(of: URL(fileURLWithPath: path))
            var item = Item(path: path, status: .waiting, plan: nil, note: nil, size: stats.size, modified: stats.modified)
            change(&item)
            items.append(item)
        }
    }

    private func replace(_ item: Item) {
        if let index = items.firstIndex(where: { $0.path == item.path }) { items[index] = item }
        else { items.append(item) }
    }

    private func save() {
        let saved = Saved(items: items, log: log, held: Array(held))
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
    }
}
