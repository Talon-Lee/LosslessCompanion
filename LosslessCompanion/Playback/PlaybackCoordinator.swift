//
//  PlaybackCoordinator.swift
//  LosslessCompanion
//
//  佇列由這裡掌控，Music 一次只播一首。腳本播放的歌曲不帶歌單順序，放著不管就會進入自動播放，
//  所以在串流快結束時主動換到下一首。連續的本地歌曲交給同一段引擎播放才能無縫接續；
//  切換來源時先讓目前的一方完全放開 DAC，另一方才開始。所有狀態都只在主執行緒存取。
//

import Combine
import Foundation

final class PlaybackCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle, preparing, playing, paused
    }

    @Published private(set) var status = Status.idle
    @Published private(set) var queue = [QueueItem]()
    @Published private(set) var currentIndex: Int?
    @Published private(set) var sourceFormat: AudioSourceFormat?
    @Published private(set) var outputPath: OutputPath?
    @Published private(set) var lastVerification: TrackVerification?
    @Published private(set) var message: String?
    @Published var repeatMode = RepeatMode.off

    let clock = PlaybackClock()

    /// Music 的輸出是否沒有在跑，用來分辨它是卡住跳歌，還是使用者自己換歌
    var isMusicOutputStuck: () -> Bool = { false }
    /// Music 還沒開始播就跳走而且輸出沒在跑；由 App 重開它，見 musicWillRestart
    var onMusicStuck: (() -> Void)?
    /// 本地歌曲聽夠久了，算一次播放
    var onLocalPlayCounted: ((LibraryTrack) -> Void)?

    var currentItem: QueueItem? {
        currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
    }

    var activeRoute: PlaybackRoute? {
        status == .idle ? nil : currentItem?.route
    }

    private let local: LocalTransport
    private let stream: StreamTransport
    private let deviceUID: () -> String?
    private let now: () -> Date
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    /// 每次換歌或停止都會遞增，較慢回來的回呼據此判斷自己是否已過期
    private var generation = 0
    private var localRun: Range<Int>?
    /// 引擎的曲目索引加上這個值就是佇列位置。移除已播放的歌之後，它和 localRun 的起點就不一定相同
    private var engineOffset = 0
    private var engineActive = false
    private var musicActive = false
    private var ignoreMusicUntil = Date.distantPast
    private var streamFailures = 0
    private var endTimer: DispatchWorkItem?
    private var startCheck: DispatchWorkItem?
    private var playAttempts = 0
    /// Music 確實開始播這首之前，它的停止與暫停通知都只是啟動過程
    private var musicConfirmed = false
    private var streamStartedAt = Date.distantPast
    private var isRestartingMusic = false
    /// 剛重開的 Music 還在載入，回報的是上次的歌，輸出也還沒啟動，這段時間不能再判定卡住
    private var musicColdStartUntil = Date.distantPast
    /// 重開後要接回的位置；等 Music 確實開始播才跳過去，冷啟動時太早送會被蓋掉
    private var resumePosition: TimeInterval?
    /// 實際聽過的時間，拖動進度條跳過的部分不算
    private var listenedTime: TimeInterval = 0
    private var lastPosition: TimeInterval?
    private var hasCountedPlay = false

    /// 超過這個時間按「上一首」會回到歌曲開頭
    private static let restartThreshold: TimeInterval = 3
    /// 我們自己操作 Music 後，它的通知會連發幾次，這段時間不當成使用者的動作
    private static let musicSettleTime: TimeInterval = 2
    /// 離結尾這麼近時，Music 自己換歌或停止都算播完；位置每秒更新一次，不會剛好等於長度
    private static let endMargin: TimeInterval = 4
    /// 剩下這麼多時間才開始排定換歌，每次回報位置都會重排
    private static let endTimerWindow: TimeInterval = 3
    /// Music 收到播放指令約 0.3 秒才放掉目前的歌，提早送出才不會聽到自動播放的歌
    private static let playLead: TimeInterval = 0.45
    /// 暫停比換歌快
    private static let pauseLead: TimeInterval = 0.25
    /// 位置超過這裡才算 Music 真的開始播放
    private static let confirmedPosition: TimeInterval = 1
    /// Music 剛啟動時要載入資料庫，這段時間內的停止通知不算數
    private static let musicStartGrace: TimeInterval = 10
    /// Music 冷啟動時會恢復上次的停止狀態，蓋掉剛收到的播放指令，要隔一段時間檢查並重送
    private static let startCheckDelay: TimeInterval = 4
    private static let maxPlayAttempts = 4
    /// 連續這麼多首都無法串流就停下來，不要把整個歌單快速跑完
    private static let maxStreamFailures = 3
    /// 聽完一半或四分鐘算一次播放，和 Last.fm 的算法相同
    private static let playCountFraction = 0.5
    private static let playCountLimit: TimeInterval = 240
    /// 位置回報的間隔遠小於這個值，跳得比這遠就是拖動進度條
    private static let maxPositionStep: TimeInterval = 3

    init(local: LocalTransport, stream: StreamTransport, deviceUID: @escaping () -> String?, now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.local = local
        self.stream = stream
        self.deviceUID = deviceUID
        self.now = now
        self.schedule = schedule
        connectTransports()
    }

    // MARK: - Commands

    func play(items: [QueueItem], startIndex: Int) {
        guard items.indices.contains(startIndex) else { return }
        queue = items
        localRun = nil
        streamFailures = 0
        start(at: startIndex)
    }

    /// 排在目前這首之後，閒置時直接開始播放
    func playNext(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        if let currentIndex, status != .idle {
            queue.insert(contentsOf: items, at: currentIndex + 1)
            syncLocalRun()
        }
        else {
            play(items: items, startIndex: 0)
        }
    }

    /// 加到佇列最後面，閒置時直接開始播放
    func enqueue(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        if status == .idle {
            play(items: items, startIndex: 0)
        }
        else {
            queue.append(contentsOf: items)
            syncLocalRun()
        }
    }

    /// 清掉還沒播的歌，正在播的不中斷，已播放的留著；沒有在播時整份清空
    func clearUpcoming() {
        guard let currentIndex, status != .idle else {
            queue = []
            return
        }
        queue.removeSubrange((currentIndex + 1)...)
        syncLocalRun()
    }

    /// 移除已播放或還沒播的歌；正在播的不能從這裡移除，要換歌用下一首
    func remove(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        queue.remove(at: index)
        guard let currentIndex else { return }
        if index > currentIndex {
            syncLocalRun()
        }
        else {
            self.currentIndex = currentIndex - 1
            shiftLocalRun(afterRemoving: index)
        }
    }

    /// 只調整接下來的順序，正在播的和已播放的不動
    func moveUpcoming(from source: Int, to destination: Int) {
        let upcoming = QueueSections(count: queue.count, currentIndex: currentIndex).upcoming
        guard source != destination, upcoming.contains(source), upcoming.contains(destination) else { return }
        queue.insert(queue.remove(at: source), at: destination)
        syncLocalRun()
    }

    func togglePause() {
        switch status {
        case .playing: setPaused(true)
        case .paused: setPaused(false)
        default: break
        }
    }

    func next() {
        guard let currentIndex else { return }
        if currentIndex + 1 < queue.count {
            jump(to: currentIndex + 1)
        }
        else if repeatMode == .all, !queue.isEmpty {
            jump(to: 0)
        }
    }

    func previous() {
        guard let currentIndex else { return }
        if clock.elapsed > Self.restartThreshold || currentIndex == 0 {
            seek(to: 0)
        }
        else {
            jump(to: currentIndex - 1)
        }
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        if engineActive, let localRun, localRun.contains(index) {
            generation &+= 1
            select(index)
            status = .playing
            local.setPaused(false)
            local.skip(toIndex: index - engineOffset)
            return
        }
        start(at: index)
    }

    func seek(to seconds: TimeInterval) {
        guard let item = currentItem, status == .playing || status == .paused else { return }
        let target = max(0, min(seconds, item.duration))
        clock.elapsed = target
        cancelTimers()
        switch item.route {
        case .local:
            guard let format = sourceFormat else { return }
            local.seek(toFrame: min(Int64(target * format.sampleRate), max(0, format.frameCount - 1)))
        case .appleMusic:
            stream.seek(to: target)
        }
    }

    /// Music 要重開了。佇列在這裡，不會跟著消失，重開後由 musicDidRestart 從同一首接回去。
    /// 回傳 false 代表目前不是由這裡在播串流，沒有東西要接回
    func musicWillRestart() -> Bool {
        guard musicActive, status != .idle, currentItem?.route == .appleMusic else { return false }
        generation &+= 1
        cancelTimers()
        musicActive = false
        isRestartingMusic = true
        resumePosition = clock.elapsed >= Self.confirmedPosition ? clock.elapsed : nil
        stream.setPositionPolling(false)
        status = .preparing
        message = String(localized: "Apple Music 的輸出卡住了，正在重新開啟")
        return true
    }

    func musicDidRestart() {
        guard isRestartingMusic, let currentIndex else { return }
        let position = resumePosition
        musicColdStartUntil = now().addingTimeInterval(Self.musicStartGrace)
        start(at: currentIndex)
        resumePosition = position
    }

    /// 使用者直接在 Music 播放時沒有佇列可以接回，只能告訴他已經重開
    func noteMusicRestarted() {
        if status == .idle { message = String(localized: "Apple Music 的輸出卡住了，已重新開啟，請再播放一次") }
    }

    func stop() {
        generation &+= 1
        cancelTimers()
        ignoreMusicUntil = now().addingTimeInterval(Self.musicSettleTime)
        if engineActive {
            engineActive = false
            local.stop {}
        }
        if musicActive {
            musicActive = false
            stream.setPositionPolling(false)
            stream.pauseIfPlaying {}
        }
        reset(message: nil)
    }

    /// App 結束時呼叫，DAC 要先還原
    func stopForTermination() {
        generation &+= 1
        cancelTimers()
        guard engineActive else { return }
        engineActive = false
        local.stopAndWait()
    }

    // MARK: - Starting tracks

    private func start(at index: Int) {
        generation &+= 1
        cancelTimers()
        isRestartingMusic = false
        resumePosition = nil
        let token = generation
        select(index)
        outputPath = nil
        status = .preparing

        let item = queue[index]
        switch item.route {
        case .local: beginLocal(at: index, token: token)
        case .appleMusic: beginStream(item, token: token)
        }
    }

    private func select(_ index: Int) {
        currentIndex = index
        clock.elapsed = 0
        clock.duration = queue[index].duration
        sourceFormat = queue[index].route == .local ? queue[index].local?.format : nil
        message = nil
        listenedTime = 0
        lastPosition = nil
        hasCountedPlay = false
    }

    private func notePosition(_ position: TimeInterval, of item: QueueItem) {
        if let last = lastPosition, position > last, position - last <= Self.maxPositionStep {
            listenedTime += position - last
        }
        lastPosition = position
        guard !hasCountedPlay, let track = item.local,
              listenedTime >= min(item.duration * Self.playCountFraction, Self.playCountLimit) else { return }
        hasCountedPlay = true
        onLocalPlayCounted?(track)
    }

    private func beginLocal(at index: Int, token: Int) {
        guard let uid = deviceUID() else {
            reset(message: BitPerfectError.deviceNotFound.errorDescription)
            return
        }
        let run = repeatMode == .one ? index..<(index + 1) : localRun(from: index)
        guard queue[run].allSatisfy({ $0.local != nil }) else {
            reset(message: String(localized: "找不到本地檔案"))
            return
        }
        ignoreMusicUntil = now().addingTimeInterval(Self.musicSettleTime)
        musicActive = false
        stream.setPositionPolling(false)
        localRun = run
        engineOffset = run.lowerBound

        stream.pauseIfPlaying { [weak self] in
            guard let self, self.generation == token, let run = self.localRun else { return }
            self.engineActive = true
            // 等 Music 放手的這段時間，佇列可能已經改變
            self.local.play(tracks: self.queue[run].compactMap(\.local), deviceUID: uid) { [weak self] error in
                guard let self, self.generation == token else { return }
                if let error {
                    self.engineActive = false
                    self.handleLocalFailure(error.localizedDescription)
                }
                else {
                    self.status = .playing
                }
            }
        }
    }

    private func beginStream(_ item: QueueItem, token: Int) {
        guard let reference = item.stream else {
            reset(message: String(localized: "這首歌沒有對應的 Apple Music 項目"))
            return
        }
        ignoreMusicUntil = now().addingTimeInterval(Self.musicSettleTime)
        musicConfirmed = false
        streamStartedAt = now()
        playAttempts = 0

        let startMusic = { [weak self] in
            guard let self, self.generation == token else { return }
            self.musicActive = true
            self.sendPlay(reference, token: token)
        }

        localRun = nil
        if engineActive {
            // 要等輔助程序退出、DAC 還原，Music 才能接手
            engineActive = false
            local.stop(completion: startMusic)
        }
        else {
            startMusic()
        }
    }

    private func sendPlay(_ reference: StreamReference, token: Int) {
        playAttempts += 1
        stream.play(reference) { [weak self] error in
            guard let self, self.generation == token else { return }
            if let error {
                self.handleStreamFailure(error)
            }
            else {
                self.streamFailures = 0
                self.status = .playing
                self.stream.setPositionPolling(true)
                self.armStartCheck(reference, token: token)
            }
        }
    }

    private func armStartCheck(_ reference: StreamReference, token: Int) {
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.musicActive, !self.musicConfirmed else { return }
            // 還沒停止代表 Music 只是在緩衝，繼續等
            guard self.stream.isStopped else { return self.armStartCheck(reference, token: token) }
            guard self.playAttempts < Self.maxPlayAttempts else {
                return self.handleStreamFailure(MusicScriptError.failed(0, String(localized: "沒有開始播放")))
            }
            self.streamStartedAt = self.now()
            self.ignoreMusicUntil = self.now().addingTimeInterval(Self.musicSettleTime)
            self.sendPlay(reference, token: token)
        }
        startCheck = check
        schedule(Self.startCheckDelay, check)
    }

    /// 從這首開始連續的本地歌曲，同一段引擎播放才能無縫
    private func localRun(from index: Int) -> Range<Int> {
        var end = index
        while end < queue.count, queue[end].route == .local { end += 1 }
        return index..<end
    }

    /// 佇列改變後，把目前這首之後連續的本地歌曲重新交給引擎，新歌才能接在同一段播放裡
    private func syncLocalRun() {
        guard let run = localRun, let currentIndex, run.contains(currentIndex) else { return }
        let next = currentIndex + 1
        let upcoming = repeatMode == .one ? next..<next : localRun(from: next)
        localRun = run.lowerBound..<upcoming.upperBound
        if engineActive {
            local.replaceUpcoming(after: currentIndex - engineOffset, with: queue[upcoming].compactMap(\.local))
        }
    }

    /// 引擎手上的曲目沒有變，只是佇列位置往前一格。被移除的歌前面那些對不上引擎的索引了，
    /// 移出這段播放，之後跳回去時由 start 重新開始
    private func shiftLocalRun(afterRemoving index: Int) {
        guard let run = localRun else { return }
        engineOffset -= 1
        localRun = max(run.lowerBound - 1, index)..<(run.upperBound - 1)
    }

    private func setPaused(_ paused: Bool) {
        guard let item = currentItem else { return }
        status = paused ? .paused : .playing
        cancelTimers()
        ignoreMusicUntil = now().addingTimeInterval(Self.musicSettleTime)
        switch item.route {
        case .local:
            if paused {
                local.setPaused(true)
            }
            else {
                stream.pauseIfPlaying { [weak self] in self?.local.setPaused(false) }
            }
        case .appleMusic:
            if paused {
                stream.pauseIfPlaying {}
            }
            else {
                stream.resume()
            }
        }
    }

    private func advance() {
        guard let index = currentIndex else { return }
        if repeatMode == .one {
            start(at: index)
        }
        else if index + 1 < queue.count {
            start(at: index + 1)
        }
        else if repeatMode == .all, !queue.isEmpty {
            start(at: 0)
        }
        else {
            reset(message: nil)
            queue = []
        }
    }

    private func reset(message: String?) {
        generation &+= 1
        cancelTimers()
        status = .idle
        currentIndex = nil
        localRun = nil
        isRestartingMusic = false
        resumePosition = nil
        sourceFormat = nil
        outputPath = nil
        clock.elapsed = 0
        clock.duration = 0
        self.message = message
    }

    // MARK: - Failures

    /// 本地失敗時，同一首有串流可用就改走串流，音樂不中斷
    private func handleLocalFailure(_ reason: String) {
        guard let index = currentIndex, let fallback = streamFallback(at: index) else {
            reset(message: reason)
            return
        }
        queue[index] = fallback
        start(at: index)
        message = String(localized: "本地播放失敗，改用 Apple Music：\(reason)")
    }

    private func streamFallback(at index: Int) -> QueueItem? {
        let item = queue[index]
        guard item.stream != nil else { return nil }
        return QueueItem(id: item.id, title: item.title, artist: item.artist, album: item.album,
                         duration: item.duration, route: .appleMusic, local: item.local, stream: item.stream)
    }

    private func handleStreamFailure(_ error: Error) {
        musicActive = false
        streamFailures += 1
        let isPermanent = (error as? MusicScriptError) == .notAuthorized
        guard !isPermanent, streamFailures < Self.maxStreamFailures, let index = currentIndex, index + 1 < queue.count else {
            reset(message: error.localizedDescription)
            return
        }
        start(at: index + 1)
        message = error.localizedDescription
    }

    // MARK: - Transport events

    private func connectTransports() {
        local.onTrackStarted = { [weak self] index, format, path in
            guard let self, let run = self.localRun, run.contains(self.engineOffset + index) else { return }
            let queueIndex = self.engineOffset + index
            if queueIndex != self.currentIndex {
                self.select(queueIndex)
            }
            self.sourceFormat = format
            self.outputPath = path
            if self.status == .preparing { self.status = .playing }
        }
        local.onPosition = { [weak self] index, frame in
            guard let self, self.localRun != nil, self.engineOffset + index == self.currentIndex,
                  let format = self.sourceFormat else { return }
            self.clock.elapsed = Double(frame) / format.sampleRate
            if let item = self.currentItem { self.notePosition(self.clock.elapsed, of: item) }
        }
        local.onVerified = { [weak self] index, result in
            guard let self, let run = self.localRun, run.contains(self.engineOffset + index) else { return }
            self.lastVerification = TrackVerification(title: self.queue[self.engineOffset + index].title,
                                                      passed: result.passed, matchedFile: result.matchedFile)
        }
        local.onFinished = { [weak self] lastIndex in
            guard let self, self.engineActive, let run = self.localRun else { return }
            self.engineActive = false
            // 以引擎回報的為準：剛結束時才加入的歌它沒有收到，要從這裡接下去
            self.currentIndex = min(self.engineOffset + lastIndex, run.upperBound - 1)
            self.advance()
        }
        local.onInterrupted = { [weak self] reason in
            guard let self, self.engineActive else { return }
            self.engineActive = false
            self.handleLocalFailure(reason)
        }
        stream.onEvent = { [weak self] event in self?.handleStream(event) }
        stream.onProgress = { [weak self] position, trackID in self?.handleProgress(position, trackID: trackID) }
    }

    private func handleStream(_ event: StreamEvent) {
        guard now() >= ignoreMusicUntil else { return }

        // 本地播放期間使用者回到 Music 按播放，就把 DAC 交還給它
        if engineActive {
            if case .playing = event {
                stop()
                message = String(localized: "已交還給 Apple Music")
            }
            return
        }

        guard musicActive, let item = currentItem else { return }
        switch event {
        case .playing(let trackID):
            if let trackID, let expected = item.stream?.trackID, trackID != expected {
                handleForeignTrack(item)
            }
            else if status != .preparing {
                status = .playing
            }
        case .paused:
            if status == .playing, isMusicStarted {
                cancelTimers()
                status = .paused
            }
        case .stopped:
            if isNearEnd(of: item) {
                finishStream()
            }
            else if status != .preparing, isMusicStarted {
                musicActive = false
                stream.setPositionPolling(false)
                reset(message: String(localized: "Apple Music 已停止播放"))
            }
        }
    }

    /// 接近結尾時換歌是 Music 自己接上的自動播放，不是使用者的操作
    private func handleForeignTrack(_ item: QueueItem) {
        if isNearEnd(of: item) {
            finishStream()
        }
        else if !musicConfirmed, isMusicOutputStuck(), let onMusicStuck {
            // 還沒真的開始就跳走，輸出也沒在跑：不是使用者換歌，是 Music 卡住了
            if now() >= musicColdStartUntil { onMusicStuck() }
        }
        else {
            // 使用者在 Music 點了別的歌，這份佇列就不再由我們控制
            musicActive = false
            stream.setPositionPolling(false)
            reset(message: String(localized: "Apple Music 正在播放其他歌曲"))
        }
    }

    private func handleProgress(_ position: TimeInterval, trackID: String?) {
        guard musicActive, status == .playing, let item = currentItem else { return }
        if let trackID, let expected = item.stream?.trackID, trackID != expected {
            // 剛送出播放指令時，Music 回報的可能還是上一首
            if now() >= ignoreMusicUntil { handleForeignTrack(item) }
            return
        }
        if position >= Self.confirmedPosition {
            musicConfirmed = true
            if let target = resumePosition {
                resumePosition = nil
                stream.seek(to: target)
                clock.elapsed = target
                return
            }
        }
        clock.elapsed = position
        armEndTimer(remaining: item.duration - position)
    }

    private var isMusicStarted: Bool {
        musicConfirmed || now().timeIntervalSince(streamStartedAt) >= Self.musicStartGrace
    }

    private func armEndTimer(remaining: TimeInterval) {
        endTimer?.cancel()
        endTimer = nil
        guard remaining <= Self.endTimerWindow, let index = currentIndex else { return }
        let token = generation
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.musicActive, let index = self.currentIndex else { return }
            self.endTimer = nil
            // 排定之後才加入的歌也要算進去；移除已播放的歌之後位置也會變，所以這裡重新取
            if self.hasNext(after: index) {
                self.finishStream()
            }
            else {
                self.stop()
                self.queue = []
            }
        }
        endTimer = timer
        schedule(max(0, remaining - (hasNext(after: index) ? Self.playLead : Self.pauseLead)), timer)
    }

    private func hasNext(after index: Int) -> Bool {
        repeatMode != .off || index + 1 < queue.count
    }

    private func cancelTimers() {
        endTimer?.cancel()
        endTimer = nil
        startCheck?.cancel()
        startCheck = nil
    }

    private func isNearEnd(of item: QueueItem) -> Bool {
        clock.elapsed >= item.duration - Self.endMargin
    }

    private func finishStream() {
        musicActive = false
        stream.setPositionPolling(false)
        advance()
    }
}
