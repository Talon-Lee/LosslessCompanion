//
//  StreamSampleMonitor.swift
//  LosslessCompanion
//
//  用 Core Audio tap 讀 Music 送往 DAC 的樣本，只計算，不儲存音訊。tap 不碰 DAC，也不改變 Music 的輸出。
//  DAC 換取樣率後 tap 的時鐘不會跟上，一定要整組重建；Music 會等裝置就緒，所以漏掉的只是驗證，不是聲音。
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

final class MusicProcessTap {
    enum Failure: Error {
        case musicNotRunning
        case coreAudio(OSStatus)
    }

    let sampleRate: Double
    let musicPID: pid_t

    private let ring: SampleRing
    private let gapCount = Atomic<Int>(0)
    private let ioQueue = DispatchQueue(label: "MusicProcessTap.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var nextSampleTime = -1.0

    var gaps: Int { gapCount.load(ordering: .relaxed) }

    init(deviceUID: String, sampleRate: Double, ring: SampleRing) throws {
        self.sampleRate = sampleRate
        self.ring = ring
        guard let app = Self.musicApp, let process = Self.process(of: app.processIdentifier) else { throw Failure.musicNotRunning }
        musicPID = app.processIdentifier

        let tap = CATapDescription(processes: [process], deviceUID: deviceUID, stream: 0)
        tap.name = "LosslessCompanion"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(tap, &tapID))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LosslessCompanion Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // 開漂移補償就是重取樣，樣本會不一樣
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: false]],
        ]
        do {
            try Self.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, time, _, _ in
                self?.receive(input, time: time)
            })
            try Self.check(AudioDeviceStart(aggregateID, procID))
        }
        catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func receive(_ list: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let buffer = buffers.first, buffer.mNumberChannels == 2, let data = buffer.mData else { return }
        let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

        let now = time.pointee.mSampleTime
        if nextSampleTime >= 0, abs(now - nextSampleTime) > 0.5 { gapCount.add(1, ordering: .relaxed) }
        nextSampleTime = now + Double(samples / 2)

        // 環形緩衝裝的是 Int32，這裡只借用它的位元
        if !ring.write(data.assumingMemoryBound(to: Int32.self), count: samples) {
            gapCount.add(1, ordering: .relaxed)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(status) }
    }

    static var musicApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
    }

    private static func process(of pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        return status == noErr && process != kAudioObjectUnknown ? process : nil
    }
}

/// 每首歌留下區塊雜湊，同一首再播時比對。檔案只有雜湊，沒有音訊
final class StreamFingerprintStore {
    private struct Entry: Codable {
        let trackID: String
        let chunks: [UInt64]
    }

    private static let limit = 500

    private let url: URL
    private var entries: [Entry]

    init(url: URL = AppPaths.support.appendingPathComponent("stream-fingerprints-v1.json")) {
        self.url = url
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func chunks(for trackID: String) -> [UInt64]? {
        entries.last { $0.trackID == trackID }?.chunks
    }

    func save(_ chunks: [UInt64], for trackID: String) {
        entries.removeAll { $0.trackID == trackID }
        entries.append(Entry(trackID: trackID, chunks: chunks))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

enum StreamSamplingState: Equatable {
    case off
    case waiting
    /// 收不到聲音，通常是沒有系統音訊錄音權限
    case noAudio
    case lossy
    case running(StreamSampleReport)
}

final class StreamSampleMonitor {
    /// 主執行緒回呼
    var onState: ((StreamSamplingState) -> Void)?

    private static let ringCapacity = 1 << 21
    private static let scratchSamples = 1 << 15
    private static let drainInterval: DispatchTimeInterval = .milliseconds(100)
    /// 等不到無損規格就當成這首不檢查
    private static let formatTimeout: TimeInterval = 3
    private static let noAudioTimeout: TimeInterval = 5
    /// 換歌時音樂還在流出，晚一點才收尾
    private static let finishDelay: TimeInterval = 0.4
    /// 換歌時 Music 會短暫停止，不值得重建 tap
    private static let stopDelay: TimeInterval = 3

    private let queue = DispatchQueue(label: "StreamSampleMonitor", qos: .utility)
    private let store: StreamFingerprintStore
    private var ring: SampleRing?
    private var tap: MusicProcessTap?
    private var timer: DispatchSourceTimer?
    private var pendingStop: DispatchWorkItem?
    private var deviceUID: String?

    private var analyzer: StreamSampleAnalyzer?
    private var analyzedFormat: StreamFormat?
    private var trackID: String?
    private var waitingSince: Date?
    private var discardsSamples = false
    private var sawLossy = false
    private var previousTail: TimeInterval?
    private var gapsAtStart = 0
    private var runningSince: Date?
    private var hasReceivedAudio = false

    init(store: StreamFingerprintStore = StreamFingerprintStore()) {
        self.store = store
    }

    func start(deviceUID: String) {
        queue.async { [self] in
            pendingStop?.cancel()
            pendingStop = nil
            // Music 重開後是新的程序，舊的 tap 收不到東西
            if self.deviceUID != deviceUID || tap?.musicPID != MusicProcessTap.musicApp?.processIdentifier { stopTap() }
            self.deviceUID = deviceUID
            if tap == nil { startTap() }
        }
    }

    /// 獨佔開始前呼叫，回傳時 tap 已經拆掉
    func stop() {
        queue.sync { [self] in
            pendingStop?.cancel()
            pendingStop = nil
            finishTrack()
            stopTap()
            publish(.off)
        }
    }

    func stopSoon() {
        queue.async { [self] in
            guard pendingStop == nil else { return }
            analyzer?.beginSegment()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStop = nil
                self.finishTrack()
                self.stopTap()
                self.publish(.off)
            }
            pendingStop = work
            queue.asyncAfter(deadline: .now() + Self.stopDelay, execute: work)
        }
    }

    /// 換歌：規格還沒出來之前，樣本先留在環形緩衝裡
    func beginTrack(id: String?) {
        queue.async { [self] in
            guard id != trackID else { return }
            let finished = analyzer
            let finishedID = trackID
            analyzer = nil
            trackID = id
            waitingSince = Date()
            discardsSamples = false
            sawLossy = false
            publish(.waiting)
            if let finished {
                // 還留在緩衝裡的尾巴由下一首吸收，比對靠內容定位，不受影響
                queue.asyncAfter(deadline: .now() + Self.finishDelay) { [self] in finalize(finished, trackID: finishedID) }
            }
        }
    }

    func beginSegment() {
        queue.async { [self] in analyzer?.beginSegment() }
    }

    /// 開頭的 AAC 已經從頭重播，之後聽到的都是無損
    func lossyStartReplayed() {
        queue.async { [self] in
            sawLossy = false
            analyzer?.clearLossyStart()
        }
    }

    /// source 是對應的本地檔，已確認規格相同才傳入
    func setFormat(_ format: StreamFormat, reference: StreamReferenceState, makeSource: (() -> StreamReferenceSource?)?) {
        queue.async { [self] in
            guard analyzer == nil || analyzedFormat != format else { return }
            waitingSince = nil
            analyzer = nil
            guard format.isLossless else {
                discardsSamples = true
                sawLossy = true
                publish(.lossy)
                return
            }
            discardsSamples = false
            analyzedFormat = format
            let source = makeSource?()
            analyzer = StreamSampleAnalyzer(sampleRate: format.sampleRate, bitDepth: format.bitDepth,
                                            reference: source == nil && reference == .searching ? .none : reference, source: source,
                                            startedLossy: sawLossy)
            publishReport()
        }
    }

    private func startTap() {
        guard let deviceUID, let device = AudioDeviceLookup.device(forUID: deviceUID) else { return }
        let ring = self.ring ?? SampleRing(minimumCapacity: Self.ringCapacity)
        self.ring = ring
        do {
            tap = try MusicProcessTap(deviceUID: deviceUID, sampleRate: DeviceRate.nominal(of: device), ring: ring)
        }
        catch {
            print("[StreamSampleMonitor] 無法建立 tap: \(error)")
            publish(.noAudio)
            return
        }
        guard timer == nil else { return }
        hasReceivedAudio = false
        runningSince = nil
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTap() {
        timer?.cancel()
        timer = nil
        tap?.stop()
        tap = nil
    }

    private func tick() {
        rebuildIfRateChanged()
        if let waitingSince, Date().timeIntervalSince(waitingSince) >= Self.formatTimeout {
            self.waitingSince = nil
            discardsSamples = true
        }
        // 規格還沒到時讓樣本留在緩衝裡
        if analyzer != nil || discardsSamples { drain() }
        watchForNoAudio()
    }

    private func rebuildIfRateChanged() {
        guard let tap, let deviceUID, let device = AudioDeviceLookup.device(forUID: deviceUID),
              DeviceRate.nominal(of: device) != tap.sampleRate else { return }
        stopTap()
        analyzer?.markHeadUnreliable()
        startTap()
    }

    private func drain() {
        guard let ring else { return }
        var hadWindow = false
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: Self.scratchSamples)
        defer { scratch.deallocate() }
        while true {
            let count = ring.read(into: scratch, count: Self.scratchSamples)
            guard count > 0 else { break }
            let samples = UnsafeBufferPointer(start: UnsafeRawPointer(scratch).assumingMemoryBound(to: Float.self), count: count)
            if !hasReceivedAudio, samples.contains(where: { $0 != 0 }) { hasReceivedAudio = true }
            analyzer?.feed(samples)
            hadWindow = true
        }
        if hadWindow, analyzer != nil { publishReport() }
    }

    private func watchForNoAudio() {
        guard !hasReceivedAudio else { return }
        if MusicAudioProcess.isOutputRunning() == true {
            let since = runningSince ?? Date()
            runningSince = since
            if Date().timeIntervalSince(since) >= Self.noAudioTimeout {
                // 沒有消耗樣本時也要判斷，否則規格一直沒來就看不出來
                if analyzer == nil, !discardsSamples { drain() }
                if !hasReceivedAudio { publish(.noAudio) }
            }
        }
    }

    private func finishTrack() {
        guard let finished = analyzer else { return }
        analyzer = nil
        finalize(finished, trackID: trackID)
        trackID = nil
    }

    private func finalize(_ finished: StreamSampleAnalyzer, trackID: String?) {
        previousTail = finished.finish()
        guard let trackID, finished.report.isUnchanged else { return }
        store.save(finished.fingerprint.chunks, for: trackID)
    }

    private func publishReport() {
        guard let analyzer else { return }
        var report = analyzer.report
        // tap 剛建立時的跳動不算中斷
        let gaps = tap?.gaps ?? gapsAtStart
        if report.checkedSeconds == 0 { gapsAtStart = gaps }
        report.gaps = max(0, gaps - gapsAtStart)
        report.previousMissingTail = previousTail
        if let trackID, let previous = store.chunks(for: trackID) {
            report.replay = StreamFingerprint.compare(previous, analyzer.fingerprint.chunks)
        }
        publish(.running(report))
    }

    private func publish(_ state: StreamSamplingState) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }
}
