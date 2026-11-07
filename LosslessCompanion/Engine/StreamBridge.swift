//
//  StreamBridge.swift
//  LosslessCompanion
//
//  Hog 模式：Apple Music 輸出到虛擬裝置 LosslessCompanion Bridge，這裡獨佔實體 DAC，
//  把 Bridge 收到的樣本原封不動轉送過去。
//  - Bridge 的時脈透過驅動的自訂屬性 'lcfs' 跟著 DAC 走，兩邊相位鎖住，不多不少。
//  - Music 送出的 Float32 和原始整數只差幾個最小單位，四捨五入到來源位元深度的格點就還原成原樣。
//  - 和本地獨佔一樣在獨立的輔助程序裡執行：同一程序重複獨佔會失敗，程序結束也一定會還原 DAC 與預設輸出。
//  驗證過程見 Tools/ 與 README：〈大風吹〉淡入以外的 230 秒和本地 FLAC 逐樣本相同。
//

import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// MARK: - Protocol

private struct BridgeCommand: Codable {
    enum Kind: String, Codable { case configure, stop }

    let kind: Kind
    var deviceUID: String?
    var sampleRate: Double?
    var sourceBits: Int?
}

private struct BridgeEvent: Codable {
    enum Kind: String, Codable { case configured, failed, status }

    let kind: Kind
    var message: String?
    var sampleRate: Double?
    var sourceBits: Int?
    var phaseError: Double?
    var underruns: Int?
    var gaps: Int?
}

/// 橋接目前的狀態，給訊號路徑與除錯用
struct StreamBridgeStatus: Equatable {
    var sampleRate: Double
    var sourceBits: Int
    var phaseError: Double = 0
    var underruns = 0
    var gaps = 0
}

enum StreamBridgeConstants {
    static let bridgeUID = "LosslessCompanionBridge_UID"
    /// 驅動的自訂屬性：Bridge 每個名目樣本要走多快（CFNumber）
    static let clockFollow = AudioObjectPropertySelector(0x6C63_6673) // 'lcfs'
}

// MARK: - Realtime bridge (helper process)

private func bridgeAddress(_ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func getProperty<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var address = address, value = initial, size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr ? pointer.pointee : nil
    }
}

@discardableResult
private func setProperty<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
    var address = address, value = value
    return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
}

private func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

private struct BridgeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// 兩個 IOProc 共用的狀態，IOProc 裡不配置記憶體、不上鎖
private final class BridgeRing: @unchecked Sendable {
    static let frames = 1 << 19
    static let mask = frames - 1
    /// DAC 讀取位置落後 Bridge 寫入位置的樣本數
    static let delay = 4096

    let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    let writtenEnd = Atomic<Int>(Int.min)
    /// DAC 樣本時間加上它就是要讀的 Bridge 樣本時間；Int.min 代表還沒鎖定
    let delta = Atomic<Int>(Int.min)
    let sourceBits = Atomic<Int>(24)
    let underruns = Atomic<Int>(0)
    let gaps = Atomic<Int>(0)
    let lastDacEnd = Atomic<Int>(Int.min)

    #if DEBUG
    /// 測試用：LC_BRIDGE_CAPTURE 指定檔案時，把送給 DAC 的整數樣本記下來，結束時寫檔
    let capture: UnsafeMutablePointer<Int32>?
    let captureCapacity: Int
    let captureCount = Atomic<Int>(0)
    let capturePath = ProcessInfo.processInfo.environment["LC_BRIDGE_CAPTURE"]

    init() {
        samples.initialize(repeating: 0, count: Self.frames * 2)
        captureCapacity = capturePath == nil ? 0 : 192_000 * 2 * 360
        capture = capturePath == nil ? nil : UnsafeMutablePointer<Int32>.allocate(capacity: captureCapacity)
    }

    func writeCapture() {
        guard let capture, let capturePath else { return }
        let count = captureCount.load(ordering: .relaxed)
        try? Data(bytesNoCopy: capture, count: count * 4, deallocator: .none).write(to: URL(fileURLWithPath: capturePath))
    }
    #else
    init() { samples.initialize(repeating: 0, count: Self.frames * 2) }
    #endif

    func reset() {
        writtenEnd.store(Int.min, ordering: .relaxed)
        delta.store(Int.min, ordering: .relaxed)
        lastDacEnd.store(Int.min, ordering: .relaxed)
    }
}

private final class StreamBridgeCore {
    private let bridge: AudioDeviceID
    private let dac: AudioDeviceID
    private let dacUID: String
    private let dacStream: AudioStreamID
    private let originalDacRate: Double
    private let originalPhysical: AudioStreamBasicDescription
    private let originalDefault: AudioDeviceID
    private let ring = BridgeRing()
    private var procs = [(AudioDeviceID, AudioDeviceIOProcID)]()
    private var ownsHog = false
    private var changedFormat = false
    private var clock = BridgeClock()
    private(set) var configuration: (rate: Double, bits: Int)?

    init(dacUID: String) throws {
        guard let bridge = AudioDeviceLookup.device(forUID: StreamBridgeConstants.bridgeUID) else { throw BridgeError("找不到 LosslessCompanion Bridge") }
        var follow = bridgeAddress(StreamBridgeConstants.clockFollow)
        guard AudioObjectHasProperty(bridge, &follow) else { throw BridgeError("Bridge 驅動版本太舊") }
        guard let dac = AudioDeviceLookup.device(forUID: dacUID) else { throw BridgeError("找不到輸出裝置") }
        guard let stream = Self.outputStream(of: dac), let physical = Self.physicalFormat(stream) else { throw BridgeError("輸出裝置沒有輸出串流") }
        self.bridge = bridge
        self.dac = dac
        self.dacUID = dacUID
        dacStream = stream
        originalDacRate = DeviceRate.nominal(of: dac)
        originalPhysical = physical
        let current = getProperty(AudioObjectID(kAudioObjectSystemObject), bridgeAddress(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
        // 上次沒還原時預設輸出還停在 Bridge，結束時要改回 DAC
        originalDefault = current == bridge || current == 0 ? dac : current

        guard hogOwner() == -1 else { throw BridgeError("輸出裝置正被其他程式獨佔") }
        guard setProperty(dac, bridgeAddress(kAudioDevicePropertyHogMode), getpid()) == noErr, hogOwner() == getpid() else {
            throw BridgeError("無法取得獨佔")
        }
        ownsHog = true
    }

    func configure(rate: Double, sourceBits: Int) throws {
        let bits = min(max(sourceBits, 8), 24)
        if let configuration, configuration.rate == rate {
            ring.sourceBits.store(bits, ordering: .relaxed)
            self.configuration = (rate, bits)
            return
        }
        stopIO()
        ring.reset()
        guard setRate(rate, on: bridge) else { throw BridgeError("Bridge 無法切換到 \(Int(rate)) Hz") }

        let candidates = Self.availablePhysicalFormats(dacStream).filter {
            ExclusiveOutput.isDirectInteger($0) && $0.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
                && $0.mChannelsPerFrame == 2 && ($0.mSampleRate == rate || $0.mSampleRate == 0)
        }
        guard var chosen = candidates.max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }) else {
            throw BridgeError("DAC 在 \(Int(rate)) Hz 沒有不可混音的整數格式")
        }
        chosen.mSampleRate = rate
        guard setProperty(dacStream, bridgeAddress(kAudioStreamPropertyPhysicalFormat), chosen) == noErr else { throw BridgeError("無法設定 DAC 格式") }
        changedFormat = true
        guard waitFor(3, { Self.physicalFormat(dacStream).map { $0.mFormatFlags == chosen.mFormatFlags && $0.mSampleRate == rate } ?? false }),
              let virtual = Self.virtualFormat(dacStream), virtual.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, virtual.mBytesPerFrame == 8 else {
            throw BridgeError("DAC 格式沒有生效")
        }

        ring.sourceBits.store(bits, ordering: .relaxed)
        try startIO()
        clock = BridgeClock(rate: rate)
        configuration = (rate, bits)
        // Music 跟著預設輸出走
        if currentDefault() != bridge { setProperty(AudioObjectID(kAudioObjectSystemObject), bridgeAddress(kAudioHardwarePropertyDefaultOutputDevice), bridge) }
    }

    /// 每 0.5 秒呼叫一次：量兩邊的相位，用 DAC 的速度加上相位修正設定 Bridge 的時脈
    func tick() -> StreamBridgeStatus? {
        guard let configuration else { return nil }
        let now = mach_absolute_time()
        guard let b = Self.sampleTime(bridge, at: now), let d = Self.sampleTime(dac, at: now) else { return nil }
        let update = clock.update(host: now, bridgeSample: b, dacSample: d)
        if let locked = update.lockedPhase, ring.delta.load(ordering: .relaxed) == Int.min {
            ring.delta.store(Int(locked.rounded()) - BridgeRing.delay, ordering: .releasing)
        }
        var value = update.scale as CFNumber
        var follow = bridgeAddress(StreamBridgeConstants.clockFollow)
        _ = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(bridge, &follow, 0, nil, UInt32(MemoryLayout<CFNumber>.size), $0) }
        return StreamBridgeStatus(sampleRate: configuration.rate, sourceBits: configuration.bits, phaseError: update.error,
                                  underruns: ring.underruns.load(ordering: .relaxed), gaps: ring.gaps.load(ordering: .relaxed))
    }

    /// 依序停止、還原 DAC 的取樣率與格式、交還獨佔，最後才改回預設輸出：獨佔中的裝置不能設成預設
    func shutdown() {
        stopIO()
        #if DEBUG
        ring.writeCapture()
        #endif
        if ownsHog {
            _ = setRate(originalDacRate, on: dac)
            if changedFormat {
                var restored = originalPhysical
                restored.mSampleRate = originalDacRate
                setProperty(dacStream, bridgeAddress(kAudioStreamPropertyPhysicalFormat), restored)
                _ = waitFor { Self.physicalFormat(dacStream)?.mFormatFlags == originalPhysical.mFormatFlags }
                changedFormat = false
            }
            if hogOwner() == getpid() { setProperty(dac, bridgeAddress(kAudioDevicePropertyHogMode), getpid()) }
            ownsHog = false
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        _ = waitFor {
            if currentDefault() != originalDefault { setProperty(system, bridgeAddress(kAudioHardwarePropertyDefaultOutputDevice), originalDefault) }
            return currentDefault() == originalDefault
        }
        configuration = nil
    }

    // MARK: IO

    private func startIO() throws {
        let ring = ring
        let bridgeIO: AudioDeviceIOBlock = { _, inputData, inputTime, outputData, _ in
            // 自己在 Bridge 輸出端只寫靜音，和 Music 混音時加 0.0 不改變數值
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = inputs.first, let data = first.mData, first.mNumberChannels == 2 else { return }
            let frames = Int(first.mDataByteSize) / 8
            let source = data.assumingMemoryBound(to: Float.self)
            let start = Int(inputTime.pointee.mSampleTime)
            for i in 0..<frames {
                let slot = ((start + i) & BridgeRing.mask) * 2
                ring.samples[slot] = source[i * 2]
                ring.samples[slot + 1] = source[i * 2 + 1]
            }
            ring.writtenEnd.store(start + frames, ordering: .releasing)
        }
        let dacIO: AudioDeviceIOBlock = { _, _, _, outputData, outputTime in
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            guard let first = outputs.first, let data = first.mData else { return }
            let frames = Int(first.mDataByteSize) / 8
            let out = data.assumingMemoryBound(to: Int32.self)
            let dacStart = Int(outputTime.pointee.mSampleTime)
            let lastEnd = ring.lastDacEnd.load(ordering: .relaxed)
            if lastEnd != Int.min && lastEnd != dacStart { ring.gaps.add(1, ordering: .relaxed) }
            ring.lastDacEnd.store(dacStart + frames, ordering: .relaxed)

            let delta = ring.delta.load(ordering: .acquiring)
            guard delta != Int.min else { out.update(repeating: 0, count: frames * 2); return }
            let start = dacStart + delta
            let end = ring.writtenEnd.load(ordering: .acquiring)
            let bits = ring.sourceBits.load(ordering: .relaxed)
            let scale = Double(1 << (bits - 1))
            let shift = Int32(32 - bits)
            var missing = 0
            for i in 0..<frames {
                let k = start + i
                if k < end && k >= end - BridgeRing.frames + 8192 {
                    let slot = (k & BridgeRing.mask) * 2
                    for c in 0..<2 {
                        // 四捨五入到來源的格點：Music 的浮點誤差只有幾個最小單位，會回到原本的整數
                        let v = min(max((Double(ring.samples[slot + c]) * scale).rounded(), -scale), scale - 1)
                        out[i * 2 + c] = Int32(v) << shift
                    }
                }
                else {
                    out[i * 2] = 0
                    out[i * 2 + 1] = 0
                    missing += 1
                }
            }
            if missing > 0 { ring.underruns.add(missing, ordering: .relaxed) }
            #if DEBUG
            if let capture = ring.capture {
                let count = ring.captureCount.load(ordering: .relaxed)
                let n = min(frames * 2, ring.captureCapacity - count)
                if n > 0 {
                    (capture + count).update(from: out, count: n)
                    ring.captureCount.store(count + n, ordering: .relaxed)
                }
            }
            #endif
        }

        let queue = DispatchQueue(label: "StreamBridge.io", qos: .userInteractive)
        for (device, block) in [(bridge, bridgeIO), (dac, dacIO)] {
            var proc: AudioDeviceIOProcID?
            guard AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue, block) == noErr, let proc else { throw BridgeError("無法建立 IOProc") }
            procs.append((device, proc))
            // 只讀 Bridge 的輸入端：輸出端關掉，系統就不會把這個程序算成往 Bridge 出聲的 App
            if device == bridge { Self.disableOutputStreams(of: device, proc: proc) }
            guard AudioDeviceStart(device, proc) == noErr else { throw BridgeError("無法啟動輸出") }
        }
    }

    private func stopIO() {
        for (device, proc) in procs {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        procs.removeAll()
    }

    // MARK: Device helpers

    private static func disableOutputStreams(of device: AudioDeviceID, proc: AudioDeviceIOProcID) {
        var address = bridgeAddress(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let count = Int(usage.pointee.mNumberStreams)
        let flags = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        for index in 0..<count { flags[index] = 0 }
        AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
    }

    private func hogOwner() -> pid_t { getProperty(dac, bridgeAddress(kAudioDevicePropertyHogMode), pid_t(-1)) ?? -1 }

    private func currentDefault() -> AudioDeviceID {
        getProperty(AudioObjectID(kAudioObjectSystemObject), bridgeAddress(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
    }

    private func setRate(_ rate: Double, on device: AudioDeviceID) -> Bool {
        guard DeviceRate.nominal(of: device) != rate else { return true }
        DeviceRate.set(rate, device: device)
        return waitFor { DeviceRate.nominal(of: device) == rate }
    }

    private static func outputStream(of device: AudioDeviceID) -> AudioStreamID? {
        var address = bridgeAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    private static func physicalFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        getProperty(stream, bridgeAddress(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription())
    }

    private static func virtualFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        getProperty(stream, bridgeAddress(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription())
    }

    private static func availablePhysicalFormats(_ stream: AudioStreamID) -> [AudioStreamBasicDescription] {
        var address = bridgeAddress(kAudioStreamPropertyAvailablePhysicalFormats)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr else { return [] }
        var list = [AudioStreamRangedDescription](repeating: .init(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list.map(\.mFormat)
    }

    private static func sampleTime(_ device: AudioDeviceID, at host: UInt64) -> Double? {
        var input = AudioTimeStamp()
        input.mHostTime = host
        input.mFlags = .hostTimeValid
        var output = AudioTimeStamp()
        output.mFlags = .sampleTimeValid
        guard AudioDeviceTranslateTime(device, &input, &output) == noErr else { return nil }
        return output.mSampleTime
    }
}

/// 讓 Bridge 的時脈跟著 DAC：最近 30 秒的 DAC 速度當基準，再依相位誤差在約 20 秒內拉回。
/// 獨立出來才能測試
struct BridgeClock {
    static let rateWindow: TimeInterval = 30
    static let phaseTimeConstant: TimeInterval = 20
    static let maxCorrectionPPM = 50.0
    /// 量了這麼久的 DAC 速度才鎖定相位
    static let warmup: TimeInterval = 2

    struct Update {
        let scale: Double
        let error: Double
        let lockedPhase: Double?
    }

    private var rate = 44100.0
    private var points = [(host: Double, frames: Double)]()
    private var start: Double?
    private var lockedPhase: Double?
    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(rate: Double = 44100) { self.rate = rate }

    mutating func update(host: UInt64, bridgeSample: Double, dacSample: Double) -> Update {
        let t = Double(host) * Self.ticksToSeconds
        return update(seconds: t, bridgeSample: bridgeSample, dacSample: dacSample)
    }

    mutating func update(seconds t: Double, bridgeSample: Double, dacSample: Double) -> Update {
        if start == nil { start = t }
        points.append((t, dacSample))
        points.removeAll { $0.host < t - Self.rateWindow }
        let phase = bridgeSample - dacSample
        var ppm = 0.0
        if points.count > 4 {
            let t0 = points[0].host, f0 = points[0].frames
            let n = Double(points.count)
            let mx = points.reduce(0) { $0 + $1.host - t0 } / n
            let my = points.reduce(0) { $0 + $1.frames - f0 } / n
            var sxy = 0.0, sxx = 0.0
            for p in points {
                let x = p.host - t0 - mx
                sxy += x * (p.frames - f0 - my)
                sxx += x * x
            }
            if sxx > 0 { ppm = (sxy / sxx / rate - 1) * 1e6 }
        }
        guard t - start! >= Self.warmup else { return Update(scale: 1 + ppm / 1e6, error: 0, lockedPhase: nil) }
        if lockedPhase == nil { lockedPhase = phase }
        let error = phase - lockedPhase!
        let correction = max(-Self.maxCorrectionPPM, min(Self.maxCorrectionPPM, -error / Self.phaseTimeConstant / rate * 1e6))
        return Update(scale: 1 + (ppm + correction) / 1e6, error: error, lockedPhase: lockedPhase)
    }
}

// MARK: - Helper process

enum StreamBridgeHelper {
    static let launchFlag = "--stream-bridge-helper"
    private static let outputLock = NSLock()
    private static let tickInterval: TimeInterval = 0.5
    private static let statusEvery = 4

    static func run() -> Never {
        let queue = DispatchQueue(label: "StreamBridge.helper")
        var core: StreamBridgeCore?
        var ticks = 0

        func finish() -> Never {
            core?.shutdown()
            exit(0)
        }

        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { finish() }
        termination.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler {
            guard let status = core?.tick() else { return }
            ticks += 1
            if ticks % statusEvery == 0 {
                send(BridgeEvent(kind: .status, sampleRate: status.sampleRate, sourceBits: status.sourceBits,
                                 phaseError: status.phaseError, underruns: status.underruns, gaps: status.gaps))
            }
        }
        timer.resume()

        let reader = Thread {
            while let line = readLine(), let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(BridgeCommand.self, from: data) {
                queue.async {
                    switch command.kind {
                    case .stop:
                        finish()
                    case .configure:
                        do {
                            if core == nil { core = try StreamBridgeCore(dacUID: command.deviceUID ?? "") }
                            try core?.configure(rate: command.sampleRate ?? 44100, sourceBits: command.sourceBits ?? 24)
                            send(BridgeEvent(kind: .configured, sampleRate: core?.configuration?.rate, sourceBits: core?.configuration?.bits))
                        }
                        catch {
                            send(BridgeEvent(kind: .failed, message: error.localizedDescription))
                            finish()
                        }
                    }
                }
            }
            // App 結束時 stdin 會關閉，不能把 DAC 留在獨佔狀態
            queue.async { finish() }
        }
        reader.start()
        dispatchMain()
    }

    private static func send(_ event: BridgeEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(UInt8(ascii: "\n"))
        outputLock.lock()
        try? FileHandle.standardOutput.write(contentsOf: data)
        outputLock.unlock()
    }
}

// MARK: - App side

/// 方法會阻塞到輔助程序回應，請勿在主執行緒呼叫 configure 與 stop。回呼在主執行緒執行
final class StreamBridgeClient {
    private static let activeFlag = Atomic<Bool>(false)

    /// 橋接期間預設輸出是 Bridge，裝置記憶與取樣率切換據此略過
    static var isActive: Bool { activeFlag.load(ordering: .sequentiallyConsistent) }

    /// 已安裝支援時脈跟隨的 Bridge 驅動
    static var isInstalled: Bool {
        guard let bridge = AudioDeviceLookup.device(forUID: StreamBridgeConstants.bridgeUID) else { return false }
        var address = bridgeAddress(StreamBridgeConstants.clockFollow)
        return AudioObjectHasProperty(bridge, &address)
    }

    /// 讀 Bridge 的輸入端在 macOS 看來就是錄音，沒有麥克風權限時只會收到靜音
    static var hasMicrophoneAccess: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// 第一次使用時跳出詢問；已經回答過就直接回傳結果。回呼在主執行緒
    static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { completion(granted) } }
        default: completion(false)
        }
    }

    /// 上次橋接沒有正常結束時，預設輸出可能還停在 Bridge
    static func recoverDefaultOutput(to uid: String?) {
        guard !isActive, AudioDeviceLookup.defaultOutputUID() == StreamBridgeConstants.bridgeUID,
              let uid, let device = AudioDeviceLookup.device(forUID: uid) else { return }
        setProperty(AudioObjectID(kAudioObjectSystemObject), bridgeAddress(kAudioHardwarePropertyDefaultOutputDevice), device)
    }

    var onStatus: ((StreamBridgeStatus?) -> Void)?
    /// 輔助程序自己結束（失敗或意外）時通知 App，參數是原因
    var onEnded: ((String?) -> Void)?

    private static let startTimeout: TimeInterval = 10
    private static let stopTimeout: TimeInterval = 4

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pendingLine = Data()
    private var replySignal: DispatchSemaphore?
    private var replyError: String?
    private var exitSignal: DispatchSemaphore?
    private var stopping = false
    private var deviceUID: String?
    private var configuration: (deviceUID: String, rate: Double, bits: Int)?

    /// 橋接目前的取樣率，沒在執行時是 nil
    var configuredRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        return process == nil ? nil : configuration?.rate
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process != nil
    }

    func isConfigured(deviceUID: String, rate: Double, bits: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard process != nil, let configuration else { return false }
        return configuration.deviceUID == deviceUID && configuration.rate == rate && configuration.bits == bits
    }

    func configure(deviceUID: String, rate: Double, sourceBits: Int) throws {
        lock.lock()
        let otherDevice = process != nil && self.deviceUID != deviceUID
        lock.unlock()
        if otherDevice { stop() }

        try launchIfNeeded(deviceUID: deviceUID)
        let reply = DispatchSemaphore(value: 0)
        lock.lock()
        replySignal = reply
        replyError = nil
        lock.unlock()
        send(BridgeCommand(kind: .configure, deviceUID: deviceUID, sampleRate: rate, sourceBits: sourceBits))
        guard reply.wait(timeout: .now() + Self.startTimeout) == .success else {
            stop()
            throw BridgeError("橋接輔助程序沒有回應")
        }
        lock.lock()
        let failure = replyError
        if failure == nil { configuration = (deviceUID, rate, sourceBits) }
        lock.unlock()
        if let failure { throw BridgeError(failure) }
    }

    /// 同步完成，返回時 DAC 已交還、預設輸出已改回
    func stop() {
        lock.lock()
        guard let process else {
            lock.unlock()
            return
        }
        stopping = true
        let exited = DispatchSemaphore(value: 0)
        exitSignal = exited
        lock.unlock()

        send(BridgeCommand(kind: .stop))
        if exited.wait(timeout: .now() + Self.stopTimeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + Self.stopTimeout)
        }
    }

    private func launchIfNeeded(deviceUID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }
        guard let executable = Bundle.main.executableURL else { throw BridgeError("找不到輔助程序") }

        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [StreamBridgeHelper.launchFlag]
        let commandPipe = Pipe()
        let eventPipe = Pipe()
        helper.standardInput = commandPipe
        helper.standardOutput = eventPipe
        helper.standardError = FileHandle.nullDevice
        eventPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        helper.terminationHandler = { [weak self] exited in
            eventPipe.fileHandleForReading.readabilityHandler = nil
            self?.helperExited(exited)
        }

        Self.activeFlag.store(true, ordering: .sequentiallyConsistent)
        stopping = false
        pendingLine.removeAll()
        do {
            try helper.run()
        }
        catch {
            Self.activeFlag.store(false, ordering: .sequentiallyConsistent)
            throw BridgeError("無法啟動橋接輔助程序：\(error.localizedDescription)")
        }
        process = helper
        input = commandPipe.fileHandleForWriting
        self.deviceUID = deviceUID
    }

    private func send(_ command: BridgeCommand) {
        lock.lock()
        let handle = input
        lock.unlock()
        guard var data = try? JSONEncoder().encode(command) else { return }
        data.append(UInt8(ascii: "\n"))
        try? handle?.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        lock.lock()
        pendingLine.append(data)
        var events = [BridgeEvent]()
        while let end = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
            if let event = try? JSONDecoder().decode(BridgeEvent.self, from: pendingLine[pendingLine.startIndex..<end]) {
                events.append(event)
            }
            pendingLine.removeSubrange(pendingLine.startIndex...end)
        }
        lock.unlock()

        for event in events {
            switch event.kind {
            case .configured, .failed:
                lock.lock()
                replyError = event.kind == .failed ? (event.message ?? "橋接失敗") : nil
                let signal = replySignal
                replySignal = nil
                lock.unlock()
                signal?.signal()
            case .status:
                let status = StreamBridgeStatus(sampleRate: event.sampleRate ?? 0, sourceBits: event.sourceBits ?? 24,
                                                phaseError: event.phaseError ?? 0, underruns: event.underruns ?? 0, gaps: event.gaps ?? 0)
                DispatchQueue.main.async { self.onStatus?(status) }
            }
        }
    }

    private func helperExited(_ exited: Process) {
        lock.lock()
        guard process === exited else {
            lock.unlock()
            return
        }
        process = nil
        input = nil
        configuration = nil
        let clean = stopping
        let failure = replyError
        let signal = exitSignal
        let reply = replySignal
        let uid = deviceUID
        exitSignal = nil
        replySignal = nil
        lock.unlock()

        Self.activeFlag.store(false, ordering: .sequentiallyConsistent)
        if !clean {
            // 輔助程序被殺掉時系統會收回獨佔，但格式與預設輸出要自己改回
            ExclusiveOutput.recoverStrandedDevices()
            Self.recoverDefaultOutput(to: uid)
        }
        reply?.signal()
        signal?.signal()
        DispatchQueue.main.async {
            self.onStatus?(nil)
            if !clean { self.onEnded?(failure ?? "橋接輔助程序意外結束") }
        }
    }
}
