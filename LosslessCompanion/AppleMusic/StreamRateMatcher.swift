//
//  StreamRateMatcher.swift
//  LosslessCompanion
//
//  串流走系統音訊，能做的只有讓 DAC 跟上 Music 輸出的取樣率。
//  LosslessSwitcher 正在執行時完全不動作，避免兩個 App 同時切換同一台 DAC。
//

import AppKit
import CoreAudio
import Foundation
import Synchronization

final class StreamRateMatcher {
    private let watcher = MusicFormatWatcher()
    private let deviceUID: () -> String?
    private var pendingSwitch: DispatchSourceTimer?
    private var rateWatch: DispatchSourceTimer?

    /// Music 遲遲沒有開始輸出時就放棄這次切換，下一次播放會重新判斷
    private static let outputStartTimeout: TimeInterval = 6
    private static let rateChangeTimeout: TimeInterval = 3
    private static let losslessSwitcherBundleID = "com.vincent-neo.LosslessSwitcher"

    /// 主執行緒回呼
    var onFormat: ((StreamFormat) -> Void)?
    var onPlaybackChanged: ((Bool) -> Void)?
    var onSignal: ((MusicLogSignal) -> Void)?
    var onTrackChanged: ((String?) -> Void)?
    /// DAC 換好取樣率花的時間
    var onRateSwitched: ((TimeInterval) -> Void)?

    /// Hog 模式：串流經由 Bridge 橋接到獨佔的 DAC，換歌時改的是橋接的取樣率與格點
    var bridge: StreamBridgeClient?
    var usesBridge: () -> Bool = { false }
    private let bridgeQueue = DispatchQueue(label: "StreamRateMatcher.bridge", qos: .userInitiated)
    /// 本地獨佔要用 DAC 時暫停橋接，直到串流再次開始
    private let bridgeHeld = Atomic<Bool>(false)

    var currentFormat: StreamFormat? { watcher.currentFormat }
    var currentTrackFormat: StreamFormat? { watcher.currentTrackFormat }
    var isMusicPlaying: Bool { watcher.isMusicPlaying }

    init(deviceUID: @escaping () -> String?) {
        self.deviceUID = deviceUID
    }

    func start() {
        watcher.onFormat = { [weak self] format in
            self?.onFormat?(format)
            self?.apply(format)
        }
        watcher.onPlaybackChanged = { [weak self] playing in self?.onPlaybackChanged?(playing) }
        watcher.onSignal = { [weak self] signal in self?.onSignal?(signal) }
        watcher.onTrackChanged = { [weak self] id in self?.onTrackChanged?(id) }
        watcher.start()
    }

    func stop() {
        pendingSwitch?.cancel()
        pendingSwitch = nil
        watcher.stop()
    }

    /// 本地播放結束後 Music 若還在播，DAC 要跟回它的規格
    func reapply() {
        if !BitPerfectClient.isExclusive { bridgeHeld.store(false, ordering: .relaxed) }
        if watcher.isMusicPlaying, let format = watcher.currentFormat { apply(format) }
        else if watcher.isMusicPlaying { ensureBridge() }
    }

    // MARK: - Hog bridge

    /// Music 開始輸出前先把橋接開好，Music 一開始就輸出到 Bridge。
    /// 規格還不知道時先用上一首或 DAC 目前的取樣率，日誌出現後再調整
    func ensureBridge(completion: (() -> Void)? = nil) {
        bridgeHeld.store(false, ordering: .relaxed)
        guard usesBridge(), let bridge, !bridge.isRunning, !BitPerfectClient.isExclusive,
              let uid = deviceUID(), let device = AudioDeviceLookup.device(forUID: uid) else {
            completion?()
            return
        }
        let format = watcher.currentFormat
        let rate = DeviceRate.closestSupported(to: format?.sampleRate ?? DeviceRate.nominal(of: device), device: device)
            ?? DeviceRate.nominal(of: device)
        configureBridge(uid: uid, rate: rate, bits: Self.gridBits(format), since: Date(), completion: completion)
    }

    /// 本地獨佔開始前呼叫，返回時 DAC 已交還。會等排隊中的設定做完，避免它在交還後又把橋接開起來
    func stopBridgeForExclusive() {
        bridgeHeld.store(true, ordering: .relaxed)
        bridgeQueue.sync { bridge?.stop() }
    }

    /// 閒置或結束時交還 DAC
    func stopBridge(wait: Bool = false) {
        guard let bridge else { return }
        if wait { bridgeQueue.sync { bridge.stop() } }
        else { bridgeQueue.async { bridge.stop() } }
    }

    /// 有損或不知道位元深度時四捨五入到 24-bit，對 Float32 來說等於原樣
    static func gridBits(_ format: StreamFormat?) -> Int {
        guard let format, format.isLossless, format.bitDepth > 0 else { return 24 }
        return min(format.bitDepth, 24)
    }

    private func applyBridge(_ format: StreamFormat) {
        guard let bridge, !BitPerfectClient.isExclusive, !bridgeHeld.load(ordering: .relaxed),
              let uid = deviceUID(), let device = AudioDeviceLookup.device(forUID: uid),
              let rate = DeviceRate.closestSupported(to: format.sampleRate, device: device) else { return }
        let bits = Self.gridBits(format)
        guard !bridge.isConfigured(deviceUID: uid, rate: rate, bits: bits) else { return }

        // 只改格點或橋接還沒開：直接設定。要換取樣率時和直接切 DAC 一樣，等 Music 的輸出跑起來才換
        if !bridge.isRunning || bridge.configuredRate == rate {
            configureBridge(uid: uid, rate: rate, bits: bits, since: Date())
            return
        }
        let deadline = Date().addingTimeInterval(Self.outputStartTimeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            if MusicAudioProcess.isOutputRunning() != false {
                timer?.cancel()
                self.pendingSwitch = nil
                self.configureBridge(uid: uid, rate: rate, bits: bits, since: Date())
            }
            else if Date() >= deadline {
                timer?.cancel()
                self.pendingSwitch = nil
            }
        }
        pendingSwitch = timer
        timer.resume()
    }

    private func configureBridge(uid: String, rate: Double, bits: Int, since start: Date, completion: (() -> Void)? = nil) {
        guard let bridge else {
            completion?()
            return
        }
        bridgeQueue.async { [weak self] in
            guard let self, !self.bridgeHeld.load(ordering: .relaxed), !BitPerfectClient.isExclusive else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let wasRate = bridge.configuredRate
            var failure: Error?
            do { try bridge.configure(deviceUID: uid, rate: rate, sourceBits: bits) }
            catch { failure = error }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                if failure == nil, wasRate != rate { self.onRateSwitched?(elapsed) }
                if let failure { self.onBridgeFailed?(failure.localizedDescription) }
                completion?()
            }
        }
    }

    /// 橋接開不起來時通知 App，主執行緒回呼
    var onBridgeFailed: ((String) -> Void)?

    static var isLosslessSwitcherRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: losslessSwitcherBundleID).isEmpty
    }

    private func apply(_ format: StreamFormat) {
        pendingSwitch?.cancel()
        pendingSwitch = nil
        if usesBridge() { return applyBridge(format) }
        guard !Self.isLosslessSwitcherRunning, !BitPerfectClient.isExclusive,
              let uid = deviceUID(), let device = AudioDeviceLookup.device(forUID: uid),
              let rate = DeviceRate.closestSupported(to: format.sampleRate, device: device),
              DeviceRate.nominal(of: device) != rate else { return }

        // 切換撞上 Music 正在啟動輸出時，Music 有機率卡死到重開為止，所以一定等它的輸出跑起來才切。
        // 此時歌曲才剛開始，Music 會等裝置就緒再繼續，開頭不會被切掉
        let deadline = Date().addingTimeInterval(Self.outputStartTimeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            if MusicAudioProcess.isOutputRunning() != false {
                timer?.cancel()
                self.pendingSwitch = nil
                guard !BitPerfectClient.isExclusive, !Self.isLosslessSwitcherRunning else { return }
                self.waitForRate(rate, device: device, since: Date())
                DeviceRate.set(rate, device: device)
            }
            else if Date() >= deadline {
                timer?.cancel()
                self.pendingSwitch = nil
            }
        }
        pendingSwitch = timer
        timer.resume()
    }

    private func waitForRate(_ rate: Double, device: AudioDeviceID, since start: Date) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self, weak timer] in
            let elapsed = Date().timeIntervalSince(start)
            if DeviceRate.nominal(of: device) == rate {
                timer?.cancel()
                self?.rateWatch = nil
                self?.onRateSwitched?(elapsed)
            }
            else if elapsed >= Self.rateChangeTimeout {
                timer?.cancel()
                self?.rateWatch = nil
            }
        }
        rateWatch = timer
        timer.resume()
    }
}

enum DeviceRate {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func nominal(of device: AudioDeviceID) -> Double {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    static func set(_ rate: Double, device: AudioDeviceID) {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    static func closestSupported(to rate: Double, device: AudioDeviceID) -> Double? {
        var address = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return nil }
        return ranges.map(\.mMinimum).min { abs($0 - rate) < abs($1 - rate) }
    }
}

/// 列出可選擇的輸出裝置
struct OutputDeviceInfo: Identifiable, Hashable {
    let uid: String
    let name: String

    var id: String { uid }

    static func all() -> [OutputDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }

        return devices.compactMap { device in
            guard hasOutput(device), let uid = AudioDeviceLookup.uid(of: device) else { return nil }
            return OutputDeviceInfo(uid: uid, name: name(of: device))
        }
    }

    static func name(uid: String) -> String? {
        AudioDeviceLookup.device(forUID: uid).map(name(of:))
    }

    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return String(localized: "未知裝置") }
        return name.takeRetainedValue() as String
    }
}
