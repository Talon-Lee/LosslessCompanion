//
//  AppleMusicTransport.swift
//  LosslessCompanion
//
//  讓 Music 在背景播放。腳本指令不會把它帶到前景，只有 Music 沒開時才會被啟動。
//  腳本播放的歌曲不帶歌單順序，once 參數對串流也沒有作用，播完 Music 會接上自動播放的電台，
//  所以換歌由 PlaybackCoordinator 負責，這裡回報目前的歌曲與位置。
//

import AppKit
import Foundation

final class AppleMusicTransport: NSObject, StreamTransport {
    var onEvent: ((StreamEvent) -> Void)?
    var onProgress: ((TimeInterval, String?) -> Void)?
    var onSeek: (() -> Void)?

    private let runner: MusicScriptRunner
    private var playerState: String?
    private var pollTimer: Timer?
    private var isPolling = false

    var isStopped: Bool { playerState == "Stopped" }

    /// Music 腳本字典裡 pause 指令的事件代碼 'hook' / 'Paus'
    private static let eventClass: AEEventClass = 0x686F_6F6B
    private static let pauseEvent: AEEventID = 0x5061_7573
    /// 串流時 Music 可能要四秒多才真的停下
    private static let pauseTimeout: TimeInterval = 6
    private static let pollInterval: TimeInterval = 1

    init(runner: MusicScriptRunner = .shared) {
        self.runner = runner
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfoChanged(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"), object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        pollTimer?.invalidate()
    }

    /// Music 開始播放前呼叫，做完再呼叫參數。Hog 模式用來先把橋接開好
    var prepare: ((@escaping () -> Void) -> Void)?

    func play(_ reference: StreamReference, completion: @escaping (Error?) -> Void) {
        guard let prepare else { return start(reference, completion: completion) }
        prepare { [weak self] in self?.start(reference, completion: completion) }
    }

    private func start(_ reference: StreamReference, completion: @escaping (Error?) -> Void) {
        do {
            let script = try MusicScripts.play(playlistID: reference.playlistID, trackID: reference.trackID)
            runner.run(script) { result in
                if case .failure(let error) = result { completion(error) }
                else { completion(nil) }
            }
        }
        catch {
            completion(error)
        }
    }

    func resume() {
        guard let prepare else { return runner.run(MusicScripts.resume) { _ in } }
        prepare { [weak self] in self?.runner.run(MusicScripts.resume) { _ in } }
    }

    func seek(to seconds: TimeInterval) {
        onSeek?()
        runner.run(MusicScripts.seek(to: seconds)) { _ in }
    }

    func setVolume(_ volume: Int) {
        runner.run(MusicScripts.setVolume(volume)) { _ in }
    }

    func readVolume(completion: @escaping (Int?) -> Void) {
        guard runner.isMusicRunning else { return completion(nil) }
        runner.run(MusicScripts.volume) { result in
            if case .success(let descriptor) = result { completion(Int(descriptor.int32Value)) }
            else { completion(nil) }
        }
    }

    func readProcessing(completion: @escaping (MusicProcessing?) -> Void) {
        guard runner.isMusicRunning else { return completion(nil) }
        runner.run(MusicScripts.processing) { result in
            guard case .success(let list) = result, list.numberOfItems == 6 else { return completion(nil) }
            completion(MusicProcessing(volume: Int(list.atIndex(1)?.int32Value ?? 100),
                                       isMuted: list.atIndex(2)?.booleanValue ?? false,
                                       isEQEnabled: list.atIndex(3)?.booleanValue ?? false,
                                       isAirPlay: list.atIndex(4)?.booleanValue ?? false,
                                       trackAdjustment: Int(list.atIndex(5)?.int32Value ?? 0),
                                       trackEQ: list.atIndex(6)?.stringValue ?? ""))
        }
    }

    func pauseIfPlaying(completion: @escaping () -> Void) {
        guard runner.isMusicRunning else { return completion() }
        if let playerState {
            guard playerState == "Playing" else { return completion() }
            sendPause(completion: completion)
            return
        }
        // App 剛啟動時還沒收過通知，要先問一次
        runner.run(MusicScripts.isPlaying) { [weak self] result in
            guard let self else { return completion() }
            if case .success(let descriptor) = result, descriptor.booleanValue {
                self.sendPause(completion: completion)
            }
            else {
                completion()
            }
        }
    }

    /// 送出後不等回覆，改等狀態通知並設上限：已經不在播放的 Music 不會再回報
    private func sendPause(completion: @escaping () -> Void) {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
        let event = NSAppleEventDescriptor(eventClass: Self.eventClass, eventID: Self.pauseEvent,
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        guard (try? event.sendEvent(options: [.noReply], timeout: 1)) != nil else { return completion() }

        let deadline = Date().addingTimeInterval(Self.pauseTimeout)
        func check() {
            if playerState != "Playing" && playerState != nil || Date() >= deadline {
                completion()
            }
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
            }
        }
        check()
    }

    func setPositionPolling(_ enabled: Bool) {
        guard enabled != isPolling else { return }
        isPolling = enabled
        pollTimer?.invalidate()
        pollTimer = nil
        guard enabled else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        // Music 被關掉時不會送出通知
        guard runner.isMusicRunning else {
            setPositionPolling(false)
            onEvent?(.stopped)
            return
        }
        runner.run(MusicScripts.playerProgress) { [weak self] result in
            guard let self, self.isPolling, case .success(let descriptor) = result,
                  descriptor.numberOfItems == 2, let position = descriptor.atIndex(1)?.doubleValue else { return }
            self.onProgress?(position, descriptor.atIndex(2)?.stringValue)
        }
    }

    @objc private func playerInfoChanged(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let state = info["Player State"] as? String
        playerState = state
        let trackID = (info["PersistentID"] as? NSNumber).map(MusicScripts.hexIdentifier(from:))
        switch state {
        case "Playing":
            onEvent?(.playing(trackID: trackID))
            // 通知沒帶歌曲時要馬上確認，否則要等下一次輪詢才知道換歌了
            if trackID == nil, isPolling { poll() }
        case "Paused": onEvent?(.paused(trackID: trackID))
        case "Stopped": onEvent?(.stopped)
        default: break
        }
    }
}
