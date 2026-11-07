// 第 4 步：Music → LosslessCompanion Bridge → 獨佔的實體 DAC。
// 1. 獨佔 DAC，切到不可混音的整數格式（和主程式的獨佔輸出相同），取樣率與 Bridge 一致。
// 2. Bridge 的輸入端（Music 寫進輸出端的樣本原樣出現在這裡）依 Bridge 的樣本時間寫進環形緩衝。
// 3. DAC 的 IOProc 用自己的樣本時間加上一個固定差距去讀環形緩衝，Float32 乘 2^31 轉成整數直接送出。
//    兩邊時脈由 clocklock 同樣的方式鎖在一起，差距固定，因此不會多出或少掉樣本。
// 4. 預設輸出暫時改成 Bridge，結束時改回原本的裝置，並還原 DAC 的取樣率、格式與靜音，交還獨佔。
// 用法：bridge <秒數> [--capture 檔案] [--rate 44100] [--audible]
//   --capture 把送到 DAC 的整數樣本（交錯雙聲道 Int32）存檔，用來和原始檔逐樣本比對
//   預設會把 DAC 靜音；--audible 保留聲音
import CoreAudio
import Foundation
import Synchronization

let bridgeUID = "LosslessCompanionBridge_UID"
let dacUID = "AppleUSBAudioEngine:XMOS:XMOS USB Audio 2.0:0000:1"
let clockFollow = AudioObjectPropertySelector(0x6C63_6673) // 'lcfs'

// MARK: - Arguments

var argSeconds = 60
var capturePath: String?
var requestedRate: Double?
var audible = false
/// Music 解碼出的來源位元深度（Music 的日誌寫著 from 16-bit source）。
/// Music 送出的 Float32 和原始整數差 1 到幾個 Float32 最小單位，四捨五入到來源的格點就還原成原始值
var sourceBits = 24
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--capture": capturePath = it.next()
        case "--rate": requestedRate = it.next().flatMap(Double.init)
        case "--audible": audible = true
        case "--source-bits": sourceBits = it.next().flatMap(Int.init).map { min(max($0, 8), 24) } ?? 24
        default: if let n = Int(arg) { argSeconds = n }
        }
    }
}

/// DAC 讀取位置落後 Bridge 寫入位置多少個樣本
let delayFrames = 4096
let ringFrames = 1 << 19
let ringMask = ringFrames - 1
let interval = 0.5
let rateWindow = 30.0
let phaseTimeConstant = 20.0
let maxCorrectionPPM = 50.0
let warmup = 5.0

// MARK: - CoreAudio helpers

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func device(uid: String) -> AudioDeviceID? {
    var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var uidRef = uid as CFString
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &uidRef) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return status == 0 && id != 0 ? id : nil
}

func get<T>(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = a, value = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == 0 ? value : nil
}

@discardableResult
func set<T>(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
    var a = a, value = value
    return AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), &value)
}

func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return condition()
}

func nominalRate(_ id: AudioDeviceID) -> Double { get(id, address(kAudioDevicePropertyNominalSampleRate), 0.0) ?? 0 }

func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
    guard nominalRate(id) != rate else { return true }
    set(id, address(kAudioDevicePropertyNominalSampleRate), rate)
    return waitUntil { nominalRate(id) == rate }
}

func uid(of id: AudioDeviceID) -> String? {
    var a = address(kAudioDevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == 0 else { return nil }
    return value?.takeRetainedValue() as String?
}

func outputStream(of id: AudioDeviceID) -> AudioStreamID? {
    var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == 0, size > 0 else { return nil }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &streams) == 0 else { return nil }
    return streams.first
}

func physicalFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
    get(stream, address(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription())
}

func virtualFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
    get(stream, address(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription())
}

func availablePhysicalFormats(_ stream: AudioStreamID) -> [AudioStreamRangedDescription] {
    var a = address(kAudioStreamPropertyAvailablePhysicalFormats)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(stream, &a, 0, nil, &size) == 0 else { return [] }
    var list = [AudioStreamRangedDescription](repeating: .init(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
    guard AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &list) == 0 else { return [] }
    return list
}

/// 和主程式相同的條件：不可混音的整數格式，32-bit 容器，IOProc 寫的就是送給驅動的
func isDirectInteger(_ f: AudioStreamBasicDescription) -> Bool {
    let required = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonMixable
    guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & required == required, f.mBytesPerFrame == 8,
          f.mChannelsPerFrame == 2, f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return false }
    return f.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 || f.mBitsPerChannel == 32
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    let kind = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int"
    let mix = f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 ? " non-mixable" : ""
    return "\(Int(f.mSampleRate)) Hz \(f.mBitsPerChannel)-bit \(kind) \(f.mBytesPerFrame / max(1, f.mChannelsPerFrame)) bytes/sample\(mix)"
}

func hogOwner(_ id: AudioDeviceID) -> pid_t { get(id, address(kAudioDevicePropertyHogMode), pid_t(-1)) ?? -1 }

func setFollowScale(_ id: AudioDeviceID, _ scale: Double) {
    var a = address(clockFollow)
    var value = scale as CFNumber
    _ = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<CFNumber>.size), $0) }
}

func sampleTime(_ id: AudioDeviceID, at host: UInt64) -> Double? {
    var input = AudioTimeStamp()
    input.mHostTime = host
    input.mFlags = .hostTimeValid
    var output = AudioTimeStamp()
    output.mFlags = .sampleTimeValid
    guard AudioDeviceTranslateTime(id, &input, &output) == 0 else { return nil }
    return output.mSampleTime
}

func mute(_ id: AudioDeviceID) -> UInt32? { get(id, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)) }

// MARK: - Shared state between the two IOProcs

final class Shared: @unchecked Sendable {
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * 2)
    /// Bridge 已寫入到哪個樣本時間（不含）
    let writtenEnd = Atomic<Int>(Int.min)
    /// DAC 樣本時間加上它就是要讀的 Bridge 樣本時間；Int.min 代表還沒鎖定，先輸出靜音
    let delta = Atomic<Int>(Int.min)
    let underrunFrames = Atomic<Int>(0)
    let minHeadroom = Atomic<Int>(Int.max)
    let renderedFrames = Atomic<Int>(0)
    let nonSilentFrames = Atomic<Int>(0)
    let clippedSamples = Atomic<Int>(0)
    let dacDiscontinuities = Atomic<Int>(0)
    let lastDacEnd = Atomic<Int>(Int.min)
    let bridgeDiscontinuities = Atomic<Int>(0)
    let bridgeInputCalls = Atomic<Int>(0)
    let capture: UnsafeMutablePointer<Int32>?
    let captureCapacity: Int
    let captureCount = Atomic<Int>(0)

    init(captureSamples: Int) {
        ring.initialize(repeating: 0, count: ringFrames * 2)
        captureCapacity = captureSamples
        capture = captureSamples > 0 ? UnsafeMutablePointer<Int32>.allocate(capacity: captureSamples) : nil
    }
}

// MARK: - Setup

guard let bridge = device(uid: bridgeUID) else { print("Bridge not found"); exit(1) }
guard let dac = device(uid: dacUID) else { print("DAC not found"); exit(1) }
var followAddress = address(clockFollow)
guard AudioObjectHasProperty(bridge, &followAddress) else { print("Bridge driver lacks the clock follow property"); exit(1) }
guard let dacStream = outputStream(of: dac) else { print("DAC has no output stream"); exit(1) }
guard hogOwner(dac) == -1 else { print("DAC is already exclusively owned by pid \(hogOwner(dac))"); exit(1) }

let originalDacRate = nominalRate(dac)
let originalBridgeRate = nominalRate(bridge)
let originalPhysical = physicalFormat(dacStream)!
let originalDefault = get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
let originalMute = mute(dac)
let rate = requestedRate ?? originalDacRate

let shared = Shared(captureSamples: capturePath == nil ? 0 : Int(Double(argSeconds + 5) * rate) * 2)
var procs = [(AudioDeviceID, AudioDeviceIOProcID)]()
var ownsHog = false
var changedFormat = false

func cleanup() {
    for (id, proc) in procs { AudioDeviceStop(id, proc); AudioDeviceDestroyIOProcID(id, proc) }
    procs.removeAll()
    if let originalMute { set(dac, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), originalMute) }
    if ownsHog {
        // 先還原取樣率再改回可混音格式，順序和主程式相同
        _ = setNominalRate(dac, originalDacRate)
        if changedFormat {
            var restored = originalPhysical
            restored.mSampleRate = originalDacRate
            set(dacStream, address(kAudioStreamPropertyPhysicalFormat), restored)
            _ = waitUntil { physicalFormat(dacStream)?.mFormatFlags == originalPhysical.mFormatFlags }
        }
        if hogOwner(dac) == getpid() { set(dac, address(kAudioDevicePropertyHogMode), getpid()) }
        ownsHog = false
    }
    _ = setNominalRate(bridge, originalBridgeRate)
    // 獨佔中的裝置不能設成預設輸出，所以交還獨佔之後才改回
    if originalDefault != 0 {
        let system = AudioObjectID(kAudioObjectSystemObject)
        _ = waitUntil {
            set(system, address(kAudioHardwarePropertyDefaultOutputDevice), originalDefault)
            return get(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) == originalDefault
        }
    }
}

let signalQueue = DispatchQueue(label: "bridge.signals")
var signalSources = [DispatchSourceSignal]()
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler { cleanup(); print("stopped by signal, restored"); exit(130) }
    source.resume()
    signalSources.append(source)
}

func fail(_ message: String) -> Never { print(message); cleanup(); exit(1) }

guard setNominalRate(bridge, rate) else { fail("could not set Bridge to \(rate)") }

// 獨佔 DAC 並切成不可混音的整數格式
guard set(dac, address(kAudioDevicePropertyHogMode), getpid()) == 0, hogOwner(dac) == getpid() else { fail("could not take exclusive access") }
ownsHog = true
let candidates = availablePhysicalFormats(dacStream).map(\.mFormat).filter {
    isDirectInteger($0) && ($0.mSampleRate == rate || $0.mSampleRate == 0)
}
guard var chosen = candidates.max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }) else { fail("DAC offers no direct integer format at \(rate)") }
chosen.mSampleRate = rate
guard set(dacStream, address(kAudioStreamPropertyPhysicalFormat), chosen) == 0 else { fail("could not set physical format") }
changedFormat = true
guard waitUntil(3, { physicalFormat(dacStream).map { $0.mFormatFlags == chosen.mFormatFlags && $0.mSampleRate == rate } ?? false }) else {
    fail("physical format did not settle")
}
let virtual = virtualFormat(dacStream)!
guard virtual.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, virtual.mBytesPerFrame == 8 else {
    fail("virtual format is not 32-bit integer: \(describe(virtual))")
}
print("dac: \(describe(physicalFormat(dacStream)!)), virtual \(describe(virtual)), hog pid \(hogOwner(dac))")

if !audible, originalMute != nil {
    set(dac, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(1))
    print("dac muted: \(mute(dac) == 1)")
}

// MARK: - IOProcs

/// Bridge：讀輸入端 Music 寫的樣本；自己的輸出端寫靜音（混音時加 0.0 不改變數值）
let bridgeIO: AudioDeviceIOBlock = { _, inputData, inputTime, outputData, _ in
    for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard let first = inputs.first, let data = first.mData, first.mNumberChannels == 2 else { return }
    let frames = Int(first.mDataByteSize) / 8
    let source = data.assumingMemoryBound(to: Float.self)
    let start = Int(inputTime.pointee.mSampleTime)
    let previous = shared.writtenEnd.load(ordering: .relaxed)
    if previous != Int.min && previous != start { shared.bridgeDiscontinuities.add(1, ordering: .relaxed) }
    for i in 0..<frames {
        let slot = ((start + i) & ringMask) * 2
        shared.ring[slot] = source[i * 2]
        shared.ring[slot + 1] = source[i * 2 + 1]
    }
    shared.writtenEnd.store(start + frames, ordering: .releasing)
    shared.bridgeInputCalls.add(1, ordering: .relaxed)
}

let sourceScale = Double(1 << (sourceBits - 1))
let sourceShift = Int32(32 - sourceBits)

/// DAC：依固定差距讀 Bridge 的樣本，四捨五入到來源位元深度的格點，再左移到 32-bit 的高位
let dacIO: AudioDeviceIOBlock = { _, _, _, outputData, outputTime in
    let outputs = UnsafeMutableAudioBufferListPointer(outputData)
    guard let first = outputs.first, let data = first.mData else { return }
    let frames = Int(first.mDataByteSize) / 8
    let out = data.assumingMemoryBound(to: Int32.self)
    let dacStart = Int(outputTime.pointee.mSampleTime)
    let lastEnd = shared.lastDacEnd.load(ordering: .relaxed)
    if lastEnd != Int.min && lastEnd != dacStart { shared.dacDiscontinuities.add(1, ordering: .relaxed) }
    shared.lastDacEnd.store(dacStart + frames, ordering: .relaxed)

    let delta = shared.delta.load(ordering: .acquiring)
    guard delta != Int.min else { out.update(repeating: 0, count: frames * 2); return }
    let start = dacStart + delta
    let end = shared.writtenEnd.load(ordering: .acquiring)
    let headroom = end - (start + frames)
    if headroom < shared.minHeadroom.load(ordering: .relaxed) { shared.minHeadroom.store(headroom, ordering: .relaxed) }

    var missing = 0, nonSilent = 0, clipped = 0
    for i in 0..<frames {
        let k = start + i
        if k < end && k >= end - ringFrames + 8192 {
            let slot = (k & ringMask) * 2
            for c in 0..<2 {
                let v = (Double(shared.ring[slot + c]) * sourceScale).rounded()
                let clampedValue = min(max(v, -sourceScale), sourceScale - 1)
                if clampedValue != v { clipped += 1 }
                out[i * 2 + c] = Int32(clampedValue) << sourceShift
            }
            if out[i * 2] != 0 || out[i * 2 + 1] != 0 { nonSilent += 1 }
        }
        else {
            out[i * 2] = 0; out[i * 2 + 1] = 0
            missing += 1
        }
    }
    if missing > 0 { shared.underrunFrames.add(missing, ordering: .relaxed) }
    if nonSilent > 0 { shared.nonSilentFrames.add(nonSilent, ordering: .relaxed) }
    if clipped > 0 { shared.clippedSamples.add(clipped, ordering: .relaxed) }
    shared.renderedFrames.add(frames, ordering: .relaxed)

    if let capture = shared.capture {
        let count = shared.captureCount.load(ordering: .relaxed)
        let n = min(frames * 2, shared.captureCapacity - count)
        if n > 0 {
            (capture + count).update(from: out, count: n)
            shared.captureCount.store(count + n, ordering: .relaxed)
        }
    }
}

let ioQueue = DispatchQueue(label: "bridge.io", qos: .userInteractive)
for (id, block) in [(bridge, bridgeIO), (dac, dacIO)] {
    var proc: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&proc, id, ioQueue, block) == 0, let proc else { fail("ioproc failed for \(id)") }
    guard AudioDeviceStart(id, proc) == 0 else { fail("start failed for \(id)") }
    procs.append((id, proc))
}

// Music 跟著預設輸出走
set(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), bridge)
print("default output -> \(uid(of: get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0) ?? "?")")
print("source grid \(sourceBits)-bit")
print("rate \(rate); bridge \(nominalRate(bridge)), dac \(nominalRate(dac)); delay \(delayFrames) frames")
fflush(stdout)
Thread.sleep(forTimeInterval: 1)

// MARK: - Clock lock loop (same controller as clocklock)

var info = mach_timebase_info_data_t()
mach_timebase_info(&info)
func hostSeconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9 }
struct Point { let host: Double; let frames: Double }
func slope(_ points: ArraySlice<Point>) -> Double {
    let t0 = points.first!.host, f0 = points.first!.frames
    let n = Double(points.count)
    let mx = points.reduce(0) { $0 + $1.host - t0 } / n, my = points.reduce(0) { $0 + $1.frames - f0 } / n
    var sxy = 0.0, sxx = 0.0
    for p in points { let x = p.host - t0 - mx; sxy += x * (p.frames - f0 - my); sxx += x * x }
    return sxy / sxx
}

var dacPoints = [Point](), phasePoints = [Point]()
var lockedPhase: Double?
var scale = 1.0
let start = mach_absolute_time()
var lastReport = -10.0
var maxAbsError = 0.0

for _ in 0..<Int(Double(argSeconds) / interval) {
    let now = mach_absolute_time()
    if let b = sampleTime(bridge, at: now), let d = sampleTime(dac, at: now) {
        let t = hostSeconds(now)
        dacPoints.append(Point(host: t, frames: d))
        let phase = b - d
        phasePoints.append(Point(host: t, frames: phase))
        let window = dacPoints.drop { $0.host < t - rateWindow }
        let elapsed = t - hostSeconds(start)
        let dacPPM = window.count > 4 ? (slope(window) / rate - 1) * 1e6 : 0
        if elapsed >= warmup {
            if lockedPhase == nil {
                lockedPhase = phase
                shared.delta.store(Int(phase.rounded()) - delayFrames, ordering: .releasing)
                print(String(format: "locked: phase %.0f frames, reading %d frames behind the Bridge", phase, delayFrames))
            }
            let error = phase - lockedPhase!
            maxAbsError = max(maxAbsError, abs(error))
            let correction = max(-maxCorrectionPPM, min(maxCorrectionPPM, -error / phaseTimeConstant / rate * 1e6))
            scale = 1 + (dacPPM + correction) / 1e6
        }
        setFollowScale(bridge, scale)
        if elapsed - lastReport >= 10 {
            lastReport = elapsed
            let error = lockedPhase.map { phase - $0 } ?? 0
            let headroom = shared.minHeadroom.load(ordering: .relaxed)
            print(String(format: "%5.0f s  phase %+5.1f  dac %+6.2f ppm  scale %+6.2f ppm  sound %6.1f s  underrun %d  min headroom %@  bridge gaps %d  dac gaps %d",
                         elapsed, error, dacPPM, (scale - 1) * 1e6,
                         Double(shared.nonSilentFrames.load(ordering: .relaxed)) / rate,
                         shared.underrunFrames.load(ordering: .relaxed),
                         headroom == Int.max ? "-" : String(headroom),
                         shared.bridgeDiscontinuities.load(ordering: .relaxed),
                         shared.dacDiscontinuities.load(ordering: .relaxed)))
            fflush(stdout)
        }
    }
    Thread.sleep(forTimeInterval: interval)
}

let captured = shared.captureCount.load(ordering: .relaxed)
let underrunsBeforeStop = shared.underrunFrames.load(ordering: .relaxed)
cleanup()

if let capturePath, let capture = shared.capture {
    let data = Data(bytesNoCopy: capture, count: captured * 4, deallocator: .none)
    try? data.write(to: URL(fileURLWithPath: capturePath))
    print("captured \(captured / 2) frames to \(capturePath)")
}
let settled = phasePoints.filter { $0.host >= hostSeconds(start) + warmup + 30 }
if settled.count > 10 {
    let drift = slope(settled[...])
    print(String(format: "clock: phase drift %+.4f frames/s (%+.3f ppm), max error %.1f frames", drift, drift / rate * 1e6, maxAbsError))
}
print("frames rendered \(shared.renderedFrames.load(ordering: .relaxed)), with sound \(shared.nonSilentFrames.load(ordering: .relaxed)), underrun frames \(underrunsBeforeStop) (silence before lock counts), clipped samples \(shared.clippedSamples.load(ordering: .relaxed)), bridge gaps \(shared.bridgeDiscontinuities.load(ordering: .relaxed)), dac gaps \(shared.dacDiscontinuities.load(ordering: .relaxed)), min headroom \(shared.minHeadroom.load(ordering: .relaxed))")
print("restored: default \(uid(of: get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0) ?? "?"), dac \(nominalRate(dac)) Hz \(describe(physicalFormat(dacStream)!)), hog \(hogOwner(dac)), mute \(mute(dac).map(String.init) ?? "n/a")")
