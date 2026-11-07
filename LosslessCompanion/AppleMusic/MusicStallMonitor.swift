//
//  MusicStallMonitor.swift
//  LosslessCompanion
//
//  Apple Music 偶爾會卡在啟動音訊輸出：按播放後沒有聲音，位置不動，約 8 秒後跳下一首，
//  之後每首都一樣，只有重開 Music 才恢復。實測和獨佔時切換 DAC 取樣率有關，但發生在 Music 內部，
//  這裡只負責發現與重開。佇列由本 App 掌控，重開後可以從同一首接回去，所以由 AppModel 自動處理。
//

import AppKit
import Foundation

final class MusicStallMonitor {
    /// 回傳 true 時不偵測，例如本地獨佔播放期間 Music 本來就不該有輸出
    var isSuppressed: () -> Bool = { false }
    /// 主執行緒回呼
    var onStallChanged: ((Bool) -> Void)?

    private var detector = MusicStallDetector()
    private var timer: DispatchSourceTimer?
    private var isConfirming = false
    private let runner: MusicScriptRunner

    private static let confirmGap: TimeInterval = 0.7

    init(runner: MusicScriptRunner = .shared) {
        self.runner = runner
    }

    func musicStartedPlaying() {
        detector.musicStartedPlaying(at: Date())
        startTimer()
    }

    func musicStoppedPlaying() {
        detector.musicStoppedPlaying()
        if !detector.isWaiting { stopTimer() }
    }

    func dismiss() {
        detector.reset()
        onStallChanged?(false)
        stopTimer()
    }

    /// completion 在主執行緒呼叫，此時 Music 已重新啟動，但資料庫可能還沒載入完
    func restartMusic(completion: @escaping () -> Void) {
        detector.reset()
        stopTimer()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            MusicRestarter.restart()
            DispatchQueue.main.async {
                self?.onStallChanged?(false)
                completion()
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if isSuppressed() {
            detector.reset()
            onStallChanged?(false)
            stopTimer()
            return
        }
        guard let running = MusicAudioProcess.isOutputRunning() else {
            if detector.isStalled { dismiss() }
            return
        }
        if running {
            if detector.outputStarted() { onStallChanged?(false) }
            stopTimer()
            return
        }
        if detector.shouldConfirm(at: Date()), !isConfirming {
            isConfirming = true
            confirmPositionIsStuck()
        }
    }

    /// 輸出沒啟動不一定是卡死，例如 AirPlay 不走這條路徑，所以還要確認播放位置沒有前進
    private func confirmPositionIsStuck() {
        readPosition { [weak self] first in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmGap) {
                self?.readPosition { second in
                    guard let self else { return }
                    self.isConfirming = false
                    guard let first, let second, MusicAudioProcess.isOutputRunning() == false else { return }
                    if self.detector.confirm(firstPosition: first, secondPosition: second) {
                        self.onStallChanged?(true)
                    }
                }
            }
        }
    }

    private func readPosition(completion: @escaping (Double?) -> Void) {
        runner.run(MusicScripts.playerPosition) { result in
            if case .success(let descriptor) = result { completion(descriptor.doubleValue) }
            else { completion(nil) }
        }
    }
}

/// 重開也救不回來時不能一直重開
struct MusicRestartPolicy {
    private static let window: TimeInterval = 120
    private static let limit = 2

    private var restarts = [Date]()

    mutating func allowsRestart(at date: Date) -> Bool {
        restarts.removeAll { date.timeIntervalSince($0) >= Self.window }
        guard restarts.count < Self.limit else { return false }
        restarts.append(date)
        return true
    }
}

enum MusicRestarter {
    private static let bundleID = "com.apple.Music"
    private static let quitTimeout: TimeInterval = 6
    private static let forceQuitTimeout: TimeInterval = 3

    /// 卡住的 Music 不一定回應結束要求，等不到就強制結束。會阻塞，請勿在主執行緒呼叫
    static func restart() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        if !waitForExit(running, timeout: quitTimeout) {
            running.forEach { $0.forceTerminate() }
            _ = waitForExit(running, timeout: forceQuitTimeout)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        // 重開是自動發生的，不能搶走使用者正在用的視窗
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func waitForExit(_ apps: [NSRunningApplication], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            usleep(100_000)
        }
        return apps.allSatisfy(\.isTerminated)
    }
}
