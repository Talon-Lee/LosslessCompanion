//
//  AppModel.swift
//  LosslessCompanion
//
//  組合音樂庫、Apple Music 歌單與播放。歌單比對在背景執行，結果以歌曲的 persistent ID 為索引。
//

import AppKit
import Combine
import Foundation

enum AppRuntime {
    case live
    /// 單元測試由 App 載入，不能碰 Music 或音訊裝置
    case testing
    #if DEBUG
    /// 截圖驗證介面用：只讀快取，不控制 Music，也不開啟音訊輸出
    case preview
    #endif

    static let current: AppRuntime = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .testing }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LC_PREVIEW"] != nil { return .preview }
        #endif
        return .live
    }()

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// 讀封面不影響播放；截圖驗證時也可以開啟
    var canReadMusic: Bool {
        isLive || ProcessInfo.processInfo.environment["LC_PREVIEW_READ_MUSIC"] != nil
    }
}

struct PlaylistCoverage {
    let matched: Int
    let total: Int

    var fraction: Double { total == 0 ? 0 : Double(matched) / Double(total) }

    /// 無條件捨去，還差幾首時才不會顯示 100%；加一點點是因為 0.29 × 100 會略小於 29
    static func percent(_ fraction: Double) -> Int {
        Int(fraction * 100 + 1e-9)
    }

    /// 音樂資料庫加上自己的播放列表，同一首只算一次。Apple Music 精選是訂閱來的，不算收藏
    static func library(_ entries: [MusicPlaylistEntry], playlists: [MusicPlaylist], isMatched: (String) -> Bool) -> PlaylistCoverage {
        var ids = Set(entries.map(\.trackID))
        for playlist in playlists where !playlist.isSubscription {
            ids.formUnion(playlist.entries.map(\.trackID))
        }
        return PlaylistCoverage(matched: ids.filter(isMatched).count, total: ids.count)
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings.shared
    let library: LocalLibrary
    let playlists: PlaylistStore
    let player: PlaybackCoordinator
    let musicVolume = MusicVolume()
    let navigation = NavigationModel()
    let review = MatchReviewStore()
    let playCounts = PlayCountStore()
    let albumMerges = AlbumMergeStore()
    let organizer = LibraryOrganizer()
    let folderPlaylists = FolderPlaylistStore()
    let routing: OutputRouting
    private let volumeHold: StreamVolumeHold

    @Published private(set) var matches = [String: LocalMatch]()
    @Published private(set) var index = LibraryIndex()
    /// 本地路徑對應到的 Music 歌曲
    @Published private(set) var appleEntries = [String: MusicPlaylistEntry]()
    @Published private(set) var libraryCoverage = PlaylistCoverage(matched: 0, total: 0)
    /// 剛完成的整理，顯示可以復原的提示
    @Published var organizeNotice: OrganizeRecord?
    /// 也在 Music 資料庫裡的本地檔案，改名或搬移後 Music 可能找不到
    @Published private(set) var musicFilePaths = Set<String>()
    @Published private(set) var suggester = MatchSuggester()
    /// 未匹配曲目的最佳候選分數；沒有候選的不在裡面
    @Published private(set) var reviewScores = [String: Int]()
    /// 硬碟上的重複檔案，對應到已經配對的那一份
    @Published private(set) var duplicates = [String: LibraryTrack]()
    /// 配對到 Music 喜好歌曲的本地檔案
    @Published private(set) var favoritePaths = Set<String>()
    /// Music 裡的喜好歌曲，串流沒有本地檔案時用這個判斷
    @Published private(set) var favoriteTrackIDs = Set<String>()
    @Published private(set) var outputDeviceName = ""
    /// 輸出裝置自己的音量；沒有音量控制的裝置是 nil
    @Published private(set) var deviceVolume: Float?
    @Published private(set) var isMusicStalled = false
    @Published private(set) var streamFormat: StreamFormat?
    @Published private(set) var streamPath = StreamPathStatus()
    @Published private(set) var streamSampling = StreamSamplingState.off
    /// 串流播放中第一個有問題的項目，顯示在播放列
    @Published private(set) var streamWarning: String?
    @Published private(set) var isMatching = false
    /// Hog 模式橋接的狀態；沒有在橋接時是 nil
    @Published private(set) var bridgeStatus: StreamBridgeStatus?
    /// 橋接開不起來或意外結束的原因，下次成功時清掉
    @Published private(set) var bridgeProblem: String?

    private static let fullVolumeThreshold: Float = 0.995
    private static let handbackDelay: TimeInterval = 1

    private let matchQueue = DispatchQueue(label: "AppModel.match", qos: .userInitiated)
    private let suggestionCache = MatchSuggestionCache()
    private var matchToken = 0
    private var entrySearchKeys = [String: String]()
    private var cancellables = Set<AnyCancellable>()
    private var rateMatcher: StreamRateMatcher?
    private let sampleMonitor: StreamSampleMonitor
    private var musicTransport: AppleMusicTransport?
    private var engineTransport: EngineTransport?
    let streamBridge = StreamBridgeClient()
    private var bridgeIdleTimer: Timer?
    /// Music 停下來這麼久就交還 DAC，其他 App 才能直接使用
    private static let bridgeIdleRelease: TimeInterval = 600
    private var streamTrackID: String?
    private var soundCheckSignal: Bool?
    private var lossyStart = LossyStartTracker()
    private var warningFilter = StreamWarningFilter()

    private static let streamWatchInterval: TimeInterval = 2
    private var nowPlaying: NowPlayingPublisher?
    private let stallMonitor = MusicStallMonitor()
    private var restartPolicy = MusicRestartPolicy()
    private var isRestartingMusic = false

    private init() {
        library = LocalLibrary()
        playlists = PlaylistStore()

        let routing = OutputRouting(settings: settings)
        self.routing = routing
        let volumeHold = StreamVolumeHold()
        self.volumeHold = volumeHold
        let sampleMonitor = StreamSampleMonitor()
        self.sampleMonitor = sampleMonitor
        let uid: () -> String? = { routing.currentUID }

        let stream: StreamTransport
        let local: LocalTransport
        if AppRuntime.current.isLive {
            let music = AppleMusicTransport()
            musicVolume.transport = music
            musicTransport = music
            music.onSeek = { sampleMonitor.beginSegment() }
            stream = music
            let engine = EngineTransport { [settings] uid in
                // 輔助程序要讀到原本的音量，結束時才還原得回去
                volumeHold.release()
                sampleMonitor.stop()
                return settings.outputOptions(for: uid)
            }
            engineTransport = engine
            local = engine
        }
        else {
            stream = InertStreamTransport()
            local = InertLocalTransport()
        }
        player = PlaybackCoordinator(local: local, stream: stream, deviceUID: uid)

        player.onLocalPlayCounted = { [playCounts] track in playCounts.recordPlay(of: track.path) }
        if AppRuntime.current.isLive { applyMoves(organizer.recover()) }

        Publishers.CombineLatest3(Publishers.CombineLatest4(library.$tracks, library.$addedAt, playlists.$playlists, playlists.$library),
                                  review.$decisions, albumMerges.$merges)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] sources, decisions, merges in
                let (tracks, addedAt, playlists, musicLibrary) = sources
                self?.rebuild(tracks, addedAt: addedAt, playlists: playlists, musicLibrary: musicLibrary, decisions: decisions, merges: merges)
            }
            .store(in: &cancellables)

        refreshOutputDevice()
        if AppRuntime.current.isLive { startLiveServices(deviceUID: uid) }
        else { library.updateCapabilities(uid().flatMap(ExclusiveOutput.capabilities(deviceUID:))) }
    }

    private func startLiveServices(deviceUID: @escaping () -> String?) {
        ExclusiveOutput.recoverStrandedDevices()
        StreamBridgeClient.recoverDefaultOutput(to: deviceUID())
        library.updateCapabilities(deviceUID().flatMap(ExclusiveOutput.capabilities(deviceUID:)))
        routing.onDeviceChanged = { [weak self] in
            self?.library.updateCapabilities(deviceUID().flatMap(ExclusiveOutput.capabilities(deviceUID:)))
            self?.rateMatcher?.reapply()
            self?.refreshOutputDevice()
            self?.updateStreamVolume()
        }
        routing.startListening()
        library.refreshIfStale()
        playlists.syncIfStale()
        musicVolume.refresh()

        let matcher = StreamRateMatcher(deviceUID: deviceUID)
        matcher.bridge = streamBridge
        matcher.usesBridge = { [settings] in
            settings.usesHogBridge && StreamBridgeClient.isInstalled && StreamBridgeClient.hasMicrophoneAccess
        }
        matcher.onBridgeFailed = { [weak self] reason in self?.bridgeProblem = reason }
        engineTransport?.beforeExclusive = { [weak matcher] in matcher?.stopBridgeForExclusive() }
        musicTransport?.prepare = { [weak matcher] start in
            guard let matcher else { return start() }
            matcher.ensureBridge(completion: start)
        }
        streamBridge.onStatus = { [weak self] status in
            guard let self else { return }
            let wasBridging = self.bridgeStatus != nil
            self.bridgeStatus = status
            // 開始或結束橋接時 Music 換了輸出裝置，樣本檢查要跟著換
            if wasBridging != (status != nil) {
                self.updateSampling(isMusicPlaying: self.rateMatcher?.isMusicPlaying == true,
                                    isEnabled: self.settings.verifiesStreamSamples)
            }
            if status != nil { self.bridgeProblem = nil }
        }
        streamBridge.onEnded = { [weak self] reason in self?.bridgeProblem = reason }
        settings.$usesHogBridge
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak matcher] enabled in
                if enabled { self?.requestBridgeAccess() }
                else { matcher?.stopBridge() }
            }
            .store(in: &cancellables)
        requestBridgeAccess()
        matcher.onFormat = { [weak self] format in
            guard let self else { return }
            self.streamFormat = format
            self.configureSampling(for: format)
            if self.lossyStart.formatSeen(format, trackID: self.streamTrackID) { self.replayLossyStart() }
            self.refreshStreamPath()
        }
        matcher.onPlaybackChanged = { [weak self, weak matcher] playing in
            if playing { self?.stallMonitor.musicStartedPlaying() }
            else { self?.stallMonitor.musicStoppedPlaying() }
            self?.bridgeIdleTimer?.invalidate()
            self?.bridgeIdleTimer = nil
            if playing { matcher?.ensureBridge() }
            else {
                self?.bridgeIdleTimer = Timer.scheduledTimer(withTimeInterval: Self.bridgeIdleRelease, repeats: false) { _ in
                    guard matcher?.isMusicPlaying == false else { return }
                    matcher?.stopBridge()
                }
            }
            self?.updateStreamVolume()
            self?.updateSampling(isMusicPlaying: playing, isEnabled: self?.settings.verifiesStreamSamples == true)
        }
        matcher.onSignal = { [weak self] signal in self?.apply(signal) }
        matcher.onTrackChanged = { [weak self] id in
            self?.streamTrackID = id
            self?.lossyStart.trackChanged()
            self?.streamPath.overloads = 0
            self?.streamPath.switchTime = nil
            self?.sampleMonitor.beginTrack(id: id)
        }
        matcher.onRateSwitched = { [weak self] elapsed in
            self?.streamPath.switchTime = elapsed
            self?.refreshStreamPath()
        }
        matcher.start()
        rateMatcher = matcher

        sampleMonitor.onState = { [weak self] state in self?.streamSampling = state }
        Timer.publish(every: Self.streamWatchInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.watchStream() }
            .store(in: &cancellables)
        settings.$verifiesStreamSamples
            .dropFirst()
            .sink { [weak self] enabled in
                self?.updateSampling(isMusicPlaying: self?.rateMatcher?.isMusicPlaying == true, isEnabled: enabled)
            }
            .store(in: &cancellables)

        stallMonitor.isSuppressed = { BitPerfectClient.isExclusive }
        stallMonitor.onStallChanged = { [weak self] stalled in
            if stalled { self?.recoverFromStall() }
            else { self?.isMusicStalled = false }
        }
        player.isMusicOutputStuck = { MusicAudioProcess.isOutputRunning() == false }
        player.onMusicStuck = { [weak self] in self?.recoverFromStall() }

        // 不是每首串流都有無損規格的日誌，換歌時要清掉，否則會顯示上一首的規格
        player.$currentIndex
            .removeDuplicates()
            .sink { [weak self] _ in self?.streamFormat = nil }
            .store(in: &cancellables)

        settings.$deviceUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshOutputDevice() }
            .store(in: &cancellables)

        player.$status
            .removeDuplicates()
            .filter { $0 == .idle }
            .sink { [weak self] _ in self?.rateMatcher?.reapply() }
            .store(in: &cancellables)

        // Published 在值改變之前發出，要等主執行緒下一輪才讀得到新狀態
        player.$status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateStreamVolume()
                // 交還 DAC 給 Music 時輔助程序還沒退出，等它放手再看一次
                if status == .idle {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.handbackDelay) { self?.updateStreamVolume() }
                }
            }
            .store(in: &cancellables)

        settings.outputOptionsChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStreamVolume() }
            .store(in: &cancellables)

        // 使用者可能隨時用鍵盤改系統音量，開始播放與換歌時都重新讀一次
        Publishers.Merge(player.$status.map { _ in () }, player.$currentIndex.map { _ in () })
            .sink { [weak self] in self?.refreshDeviceVolume() }
            .store(in: &cancellables)

        nowPlaying = NowPlayingPublisher(player: player)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.playlists.syncIfStale()
                self?.library.refreshIfStale()
                self?.musicVolume.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lookups

    func match(for entry: MusicPlaylistEntry) -> LocalMatch? {
        matches[entry.trackID]
    }

    /// 這首歌的本地檔案所在的專輯
    func localAlbum(for entry: MusicPlaylistEntry) -> AlbumGroup? {
        match(for: entry).flatMap { index.albumsByPath[$0.track.path] }
    }

    /// 串流中的歌曲也算，只要它有本地檔案
    func localAlbum(for item: QueueItem) -> AlbumGroup? {
        let path = item.local?.path ?? item.stream.flatMap { matches[$0.trackID]?.track.path }
        return path.flatMap { index.albumsByPath[$0] }
    }

    /// Music 資料庫裡這首歌的專輯；不在資料庫的歌（例如精選歌單裡的）沒有
    func musicAlbum(forTrackID trackID: String) -> MusicAlbum? {
        index.musicAlbumsByTrack[trackID]
    }

    /// 收錄這首歌的播放列表，依側欄順序
    func playlists(containing trackID: String) -> [MusicPlaylist] {
        playlists.playlists.filter { playlist in playlist.entries.contains { $0.trackID == trackID } }
    }

    /// 播放列表內搜尋用。正規化要做繁簡與假名轉換，很慢，每首歌只算一次
    func searchKey(for entry: MusicPlaylistEntry) -> String {
        if let key = entrySearchKeys[entry.trackID] { return key }
        let key = SearchText.normalize(entry.title + "\n" + entry.artist + "\n" + entry.album)
        entrySearchKeys[entry.trackID] = key
        return key
    }

    func isFavorite(_ item: QueueItem) -> Bool {
        if let path = item.local?.path, favoritePaths.contains(path) { return true }
        return item.stream.map { favoriteTrackIDs.contains($0.trackID) } ?? false
    }

    var albums: [AlbumGroup] { index.albums }
    var artists: [ArtistGroup] { index.artists }

    func sortedEntries(of playlist: MusicPlaylist) -> [MusicPlaylistEntry] {
        TrackSorter.sorted(playlist.entries, by: settings.trackSort(for: playlist.id), fields: \.sortFields)
    }

    func sortedTracks(_ tracks: [LibraryTrack], by sort: TrackSort) -> [LibraryTrack] {
        let addedAt = library.addedAt
        let records = playCounts.records
        return TrackSorter.sorted(tracks, by: sort) {
            $0.sortFields(addedAt: addedAt[$0.path] ?? 0, plays: records[$0.path]?.count ?? 0)
        }
    }

    func coverage(of playlist: MusicPlaylist) -> PlaylistCoverage {
        PlaylistCoverage(matched: playlist.entries.filter { matches[$0.trackID] != nil }.count,
                         total: playlist.entries.count)
    }

    /// 裝置音量若是數位縮放，樣本到了 DAC 就不是原樣
    var isDeviceAttenuated: Bool {
        (deviceVolume ?? 1) < Self.fullVolumeThreshold
    }

    func reviewStatus(of track: LibraryTrack) -> ReviewStatus {
        if let link = review.decisions.links[track.path] { return .linked(link) }
        if review.decisions.localOnly.contains(track.path) { return .localOnly }
        return index.unmatchedPaths.contains(track.path) ? .unmatched : .automatic
    }

    /// 可以放心一次連結的曲目：全部欄位都相符，而且那首歌還沒有對應的本地檔案
    func certainLinks(in tracks: [LibraryTrack]) -> [(track: LibraryTrack, entry: MusicPlaylistEntry)] {
        var used = Set<String>()
        // 分數已經算好，先用它篩掉絕大多數曲目；校閱視窗每次重繪都會呼叫
        return tracks.filter { (reviewScores[$0.path] ?? 0) >= MatchSuggester.certainScore }.compactMap { track in
            guard let best = suggester.suggestions(for: track, limit: 1).first, best.isCertain,
                  match(for: best.entry) == nil, used.insert(best.entry.trackID).inserted else { return nil }
            return (track, best.entry)
        }
    }

    /// 重複檔案不缺對應的歌曲，不用校閱。有候選的排在前面，分數高的先看
    var reviewQueue: [LibraryTrack] {
        let scores = reviewScores
        let duplicates = self.duplicates
        return index.unmatchedTracks.filter { duplicates[$0.path] == nil }.enumerated().sorted { lhs, rhs in
            let left = scores[lhs.element.path] ?? 0
            let right = scores[rhs.element.path] ?? 0
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Playback

    func play(_ playlist: MusicPlaylist, from entry: MusicPlaylistEntry? = nil, forcedRoute: PlaybackRoute? = nil, shuffled: Bool = false) {
        let preference = settings.preference(for: playlist.id)
        let built = QueueBuilder.items(for: playlist, entries: sortedEntries(of: playlist), startingAt: entry,
                                       preference: preference, forcedRoute: forcedRoute) {
            matches[$0.trackID]?.track
        }
        guard !built.items.isEmpty else { return }
        if shuffled {
            player.play(items: built.items.shuffled(), startIndex: 0)
        }
        else {
            player.play(items: built.items, startIndex: built.index)
        }
    }

    func play(tracks: [LibraryTrack], from track: LibraryTrack? = nil, shuffled: Bool = false) {
        let items = (shuffled ? tracks.shuffled() : tracks).map { QueueItem(track: $0) }
        let index = track.flatMap { tracks.firstIndex(of: $0) } ?? 0
        guard !items.isEmpty else { return }
        player.play(items: items, startIndex: shuffled ? 0 : index)
    }

    func playNext(tracks: [LibraryTrack]) {
        player.playNext(tracks.map { QueueItem(track: $0) })
    }

    func playNext(_ entries: [MusicPlaylistEntry], in playlist: MusicPlaylist) {
        player.playNext(queueItems(entries, in: playlist))
    }

    func enqueue(tracks: [LibraryTrack]) {
        player.enqueue(tracks.map { QueueItem(track: $0) })
    }

    func enqueue(_ entries: [MusicPlaylistEntry], in playlist: MusicPlaylist) {
        player.enqueue(queueItems(entries, in: playlist))
    }

    private func queueItems(_ entries: [MusicPlaylistEntry], in playlist: MusicPlaylist) -> [QueueItem] {
        QueueBuilder.items(for: playlist, entries: entries, startingAt: nil,
                           preference: settings.preference(for: playlist.id)) { matches[$0.trackID]?.track }.items
    }

    func restartMusic() {
        isMusicStalled = false
        performMusicRestart()
    }

    /// 自動重開，串流會從同一首接回去。短時間內又卡住代表重開沒有用，
    /// 這時停下來改成提示，不然 Music 會一路跳歌把佇列跑完
    private func recoverFromStall() {
        guard !isRestartingMusic else { return }
        if restartPolicy.allowsRestart(at: Date()) {
            performMusicRestart()
        }
        else {
            isMusicStalled = true
            player.stop()
        }
    }

    private func performMusicRestart() {
        guard !isRestartingMusic else { return }
        isRestartingMusic = true
        let willResume = player.musicWillRestart()
        stallMonitor.restartMusic { [weak self] in
            guard let self else { return }
            self.isRestartingMusic = false
            if willResume { self.player.musicDidRestart() }
            else { self.player.noteMusicRestarted() }
        }
    }

    func dismissStall() {
        stallMonitor.dismiss()
    }

    /// 沒有麥克風權限時 Hog 模式不啟用，串流照一般方式播放，不會變成無聲
    private func requestBridgeAccess() {
        guard settings.usesHogBridge, StreamBridgeClient.isInstalled else { return }
        StreamBridgeClient.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                if self.bridgeProblem == Self.microphoneProblem { self.bridgeProblem = nil }
                self.rateMatcher?.reapply()
            }
            else {
                self.bridgeProblem = Self.microphoneProblem
            }
        }
    }

    private static let microphoneProblem = String(localized: "沒有麥克風權限，請到「系統設定 › 隱私權與安全性 › 麥克風」打開 LosslessCompanion")

    func prepareForTermination() {
        rateMatcher?.stop()
        rateMatcher?.stopBridge(wait: true)
        player.stopForTermination()
        volumeHold.release()
    }

    /// 等這個程序結束、DAC 交還後才開新的，兩邊才不會同時搶輸出
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
                             "sh", String(getpid()), Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    // MARK: - Folder playlists

    func openFolderPlaylist(for folder: String) {
        navigation.open(.folderPlaylist(folderPlaylists.add(folder: folder).id))
    }

    /// 這個資料夾與它上面幾層，都可以變成播放列表
    func folderChoices(for folder: String) -> [String] {
        FolderPlaylistPlanner.choices(for: folder, roots: library.folders)
    }

    func removeFolderPlaylist(_ playlist: FolderPlaylist) {
        folderPlaylists.remove(id: playlist.id)
        if navigation.selection == .folderPlaylist(playlist.id) { navigation.open(.home) }
    }

    // MARK: - Organizing files

    /// 只問已經開著的 Music，不會為了這個把它叫起來
    func refreshMusicFiles() {
        guard AppRuntime.current.canReadMusic, MusicScriptRunner.shared.isMusicRunning else { return }
        MusicScriptRunner.shared.runInSubprocess(MusicScripts.fileTrackLocations) { [weak self] result in
            guard case .success(let text) = result else { return }
            let paths = Set(text.split(whereSeparator: \.isNewline).map { String($0).precomposedStringWithCanonicalMapping })
            DispatchQueue.main.async { self?.musicFilePaths = paths }
        }
    }

    func musicFileCount(in paths: [String]) -> Int {
        paths.filter { musicFilePaths.contains($0.precomposedStringWithCanonicalMapping) }.count
    }

    /// 佇列裡的檔案不能動：引擎接下來要用舊路徑開啟它們
    func isInQueue(_ paths: Set<String>) -> Bool {
        player.status != .idle && player.queue.contains { $0.local.map { paths.contains($0.path) } ?? false }
    }

    func organize(_ request: OrganizeRequest, progress: @escaping (Int, Int) -> Void = { _, _ in },
                  completion: @escaping (Result<OrganizeOutcome, Error>) -> Void) {
        guard !isInQueue(Set(request.moves.map(\.from) + request.tags.map(\.path))) else {
            completion(.failure(OrganizeError.inQueue))
            return
        }
        let organizer = self.organizer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try organizer.run(request) { done, total in DispatchQueue.main.async { progress(done, total) } }
            }
            DispatchQueue.main.async {
                if case .success(let outcome) = result { self?.finish(outcome.record) }
                completion(result)
            }
        }
    }

    func undo(_ record: OrganizeRecord, completion: @escaping (Error?) -> Void = { _ in }) {
        guard !isInQueue(Set(record.moves.map(\.to) + record.tags.map(\.path))) else {
            completion(OrganizeError.inQueue)
            return
        }
        let organizer = self.organizer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try organizer.undo(record) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.applyMoves(record.moves.reversed().map(\.reversed))
                    self.library.markOutdated(record.tags.map(\.path))
                    if let album = record.mergedAlbum { self.albumMerges.remove(folders: record.mergedFolders ?? [], from: album) }
                    self.organizer.finish(undoing: record)
                    if self.organizeNotice?.id == record.id { self.organizeNotice = nil }
                    self.library.rescan()
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        }
    }

    /// 只有選擇搬移檔案時才會碰到硬碟
    func merge(_ sources: [AlbumGroup], into target: AlbumGroup, title: String?, movesFiles: Bool,
               progress: @escaping (Int, Int) -> Void = { _, _ in }, completion: @escaping (Result<OrganizeOutcome, Error>) -> Void) {
        let name = title ?? target.title
        var request = OrganizeRequest(title: String(localized: "合併《\(name)》"))
        request.mergedAlbum = target.id
        request.mergedFolders = sources.flatMap { albumMerges.merges.merge(containing: $0.id)?.folders ?? [$0.id] }
        if movesFiles { request.moves = AlbumMergePlanner.moves(into: target, from: sources) }
        albumMerges.merge(target: target.id, sources: sources.map(\.id), title: title)
        organize(request, progress: progress) { [weak self] result in
            if case .failure = result { self?.albumMerges.remove(folders: request.mergedFolders ?? [], from: target.id) }
            completion(result)
        }
    }

    private func finish(_ record: OrganizeRecord) {
        applyMoves(record.moves)
        let destinations = Dictionary(record.moves.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
        library.markOutdated(record.tags.map { destinations[$0.path] ?? $0.path })
        organizer.finish(record)
        organizeNotice = record
        library.rescan()
    }

    private func applyMoves(_ moves: [FileMove]) {
        guard !moves.isEmpty else { return }
        library.applyMoves(moves)
        review.apply(moves)
        playCounts.apply(moves)
    }

    // MARK: - Derived data

    private func refreshOutputDevice() {
        outputDeviceName = routing.currentUID.flatMap(OutputDeviceInfo.name(uid:)) ?? String(localized: "未知裝置")
        refreshDeviceVolume()
    }

    func refreshDeviceVolume() {
        deviceVolume = routing.currentUID.flatMap(ExclusiveOutput.volume(deviceUID:))
    }

    func refreshStreamPath() {
        guard AppRuntime.current.isLive, let uid = routing.currentUID else { return }
        var path = streamPath
        path.format = streamFormat
        path.device = StreamPathProbe.device(uid: uid)
        path.soundCheck = StreamPathProbe.musicPreference("optimizeSongVolume") ?? soundCheckSignal
        path.transitions = StreamPathProbe.musicPreference("TransitionsEnabled")
        streamPath = path
        musicTransport?.readProcessing { [weak self] music in self?.streamPath.music = music }
    }

    var streamRows: [StreamCheckRow] {
        streamPath.pathRows(deviceName: outputDeviceName)
    }

    var streamVerdict: StreamVerdict {
        streamPath.verdict(deviceName: outputDeviceName, sampling: streamSampling)
    }

    #if DEBUG
    /// 預覽用：不連到 Music 也能看串流檢查的版面
    func injectPreviewStreamCheck(hasProblem: Bool) {
        streamFormat = StreamFormat(sampleRate: 96000, bitDepth: 24)
        streamPath.format = streamFormat
        streamPath.device = StreamDeviceState(sampleRate: 96000, bitDepth: 24, isInteger: true, isPhysical: true, transport: "USB", volume: 1)
        streamPath.music = MusicProcessing(volume: hasProblem ? 80 : 100, isEQEnabled: hasProblem)
        streamPath.soundCheck = hasProblem
        streamPath.transitions = false
        streamPath.soundEnhancer = false
        streamPath.switchTime = 0.42
        var report = StreamSampleReport()
        report.checkedSeconds = 63
        report.changedSeconds = hasProblem ? 63 : 0
        report.reference = hasProblem ? .different : .matching(seconds: 62, exactShare: 0.986)
        report.replay = hasProblem ? .firstPlay : .same
        report.startedLossy = hasProblem
        report.previousMissingTail = hasProblem ? 0.12 : nil
        streamSampling = .running(report)
    }
    #endif

    /// 串流時持續檢查，有問題不必打開訊號路徑也看得到
    private func watchStream() {
        guard player.activeRoute == .appleMusic, rateMatcher?.isMusicPlaying == true else {
            warningFilter = StreamWarningFilter()
            if streamWarning != nil { streamWarning = nil }
            return
        }
        refreshStreamPath()
        warningFilter.update(streamPath.firstProblem(deviceName: outputDeviceName, sampling: streamSampling))
        if streamWarning != warningFilter.warning { streamWarning = warningFilter.warning }
    }

    /// 只處理 App 自己排的串流；Music 裡直接點的歌不去動它
    private func replayLossyStart() {
        guard player.activeRoute == .appleMusic, player.clock.elapsed < LossyStartTracker.replayLimit else { return }
        musicTransport?.seek(to: 0)
        sampleMonitor.lossyStartReplayed()
    }

    private func apply(_ signal: MusicLogSignal) {
        switch signal {
        case .soundCheck(let isOn): soundCheckSignal = isOn
        case .soundEnhancer(let isOn): streamPath.soundEnhancer = isOn
        case .overload: streamPath.overloads += 1
        }
    }

    private func updateSampling(isMusicPlaying: Bool, isEnabled: Bool) {
        guard isEnabled else { return sampleMonitor.stop() }
        guard isMusicPlaying else { return sampleMonitor.stopSoon() }
        // 橋接時 Music 輸出到 Bridge，要在那裡聽
        let device = StreamBridgeClient.isActive ? StreamBridgeConstants.bridgeUID : routing.currentUID
        guard !BitPerfectClient.isExclusive, let uid = device else { return }
        sampleMonitor.start(deviceUID: uid)
        sampleMonitor.beginTrack(id: streamTrackID)
        configureSampling(for: rateMatcher?.currentTrackFormat)
    }

    /// 只有取樣率和位深都相同的本地檔才值得比對
    private func configureSampling(for format: StreamFormat?) {
        guard let format, settings.verifiesStreamSamples else { return }
        var reference = StreamReferenceState.none
        var makeSource: (() -> StreamReferenceSource?)?
        if let track = streamTrackID.flatMap({ matches[$0]?.track }) {
            if track.sampleRate == format.sampleRate, track.bitsPerSample == format.bitDepth {
                let url = URL(fileURLWithPath: track.path)
                reference = .searching
                makeSource = { try? PCMFileReader(url: url) }
            }
            else {
                reference = .otherVersion
            }
        }
        sampleMonitor.setFormat(format, reference: reference, makeSource: makeSource)
    }

    /// 「固定 100%」要連串流一起算：只固定獨佔的話，串流跟著系統音量，
    /// DAC 的音量曲線很陡，滑桿 61% 就可能是 -28 dB，切到串流會小很多
    private func updateStreamVolume() {
        let uid = routing.currentUID
        let isStreaming = rateMatcher?.isMusicPlaying == true || (player.activeRoute == .appleMusic && player.status != .paused)
        let isWanted = uid.map { settings.outputOptions(for: $0).forcesMaxVolume } == true
        volumeHold.update(deviceUID: isStreaming && isWanted && !BitPerfectClient.isExclusive ? uid : nil)
        refreshDeviceVolume()
    }

    private func rebuild(_ tracks: [LibraryTrack], addedAt: [String: Double], playlists: [MusicPlaylist],
                         musicLibrary: [MusicPlaylistEntry], decisions: MatchDecisions, merges: AlbumMerges) {
        matchToken += 1
        let token = matchToken
        isMatching = true
        matchQueue.async { [weak self, suggestionCache] in
            var seen = Set<String>()
            let entries = (musicLibrary + playlists.flatMap(\.entries)).filter { seen.insert($0.trackID).inserted }
            let resolution = MatchResolver.resolve(tracks: tracks, entries: entries, decisions: decisions)
            let coverage = PlaylistCoverage.library(musicLibrary, playlists: playlists) { resolution.matches[$0] != nil }
            var index = LibraryIndex.build(tracks: tracks, addedAt: addedAt, apple: resolution.apple, decisions: decisions, merges: merges)
            let musicAlbums = MusicRecents.allAlbums(from: musicLibrary)
            index.recentMusic = Array(musicAlbums.prefix(MusicRecents.albumLimit))
            index.musicAlbumsByTrack = MusicRecents.albumsByTrack(musicAlbums)
            suggestionCache.update(entries: entries, tracks: tracks)
            let suggester = suggestionCache.suggester
            let favoriteTrackIDs = Set(entries.filter { $0.isFavorite == true }.map(\.trackID))
            let scores = suggestionCache.scores(for: index.unmatchedTracks)
            let duplicates = MatchResolver.duplicates(in: index.unmatchedTracks, scores: scores, suggester: suggester,
                                                      matches: resolution.matches)
            DispatchQueue.main.async {
                guard let self, self.matchToken == token else { return }
                self.matches = resolution.matches
                self.favoritePaths = resolution.favorites
                self.favoriteTrackIDs = favoriteTrackIDs
                self.appleEntries = resolution.apple
                self.libraryCoverage = coverage
                self.index = index
                self.suggester = suggester
                self.reviewScores = scores
                self.duplicates = duplicates
                self.isMatching = false
            }
        }
    }
}

/// Music 的音量；本地獨佔不經過軟體音量
final class MusicVolume: ObservableObject {
    @Published var value: Double = 100

    fileprivate weak var transport: AppleMusicTransport?

    func refresh() {
        transport?.readVolume { [weak self] volume in
            if let volume { self?.value = Double(volume) }
        }
    }

    func set(_ volume: Double) {
        value = volume
        transport?.setVolume(Int(volume))
    }
}

// MARK: - Inert transports

/// 不是正式執行時使用，保證測試與截圖不會影響 Music 和 DAC
final class InertLocalTransport: LocalTransport {
    var onTrackStarted: ((Int, AudioSourceFormat, OutputPath) -> Void)?
    var onPosition: ((Int, Int64) -> Void)?
    var onVerified: ((Int, TrackResult) -> Void)?
    var onFinished: ((Int) -> Void)?
    var onInterrupted: ((String) -> Void)?

    func play(tracks: [LibraryTrack], deviceUID: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
        if let first = tracks.first { onTrackStarted?(0, first.format, .directInteger) }
    }
    func setPaused(_ paused: Bool) {}
    func seek(toFrame frame: Int64) {}
    func skip(toIndex index: Int) {}
    func replaceUpcoming(after index: Int, with tracks: [LibraryTrack]) {}
    func stop(completion: @escaping () -> Void) { completion() }
    func stopAndWait() {}
}

final class InertStreamTransport: StreamTransport {
    var onEvent: ((StreamEvent) -> Void)?
    var onProgress: ((TimeInterval, String?) -> Void)?
    var isStopped: Bool { false }

    func play(_ reference: StreamReference, completion: @escaping (Error?) -> Void) { completion(nil) }
    func resume() {}
    func pauseIfPlaying(completion: @escaping () -> Void) { completion() }
    func seek(to seconds: TimeInterval) {}
    func setPositionPolling(_ enabled: Bool) {}
}
