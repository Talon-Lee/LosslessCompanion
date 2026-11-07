// 第 3 步：讓 LosslessCompanion Bridge 的時脈跟著實體 DAC 走。
// 兩個裝置各跑一個只寫靜音的 IOProc；每 0.5 秒把同一個主機時間換算成兩邊的樣本位置，
// 兩者的差就是相位。程式用 DAC 實測的速度當基準，再依相位誤差微調，透過驅動的自訂屬性
// 'lcfs' 設定 Bridge 每個名目樣本要走多快。目標是相位差一直維持在開始鎖定時的值。
// 不發出聲音，不改預設輸出。
// 用法：clocklock <秒數> [輸出 CSV 路徑] [--open]
//   --open 只量不鎖，用來對照
import CoreAudio
import Foundation

let bridgeUID = "LosslessCompanionBridge_UID"
let dacUID = "AppleUSBAudioEngine:XMOS:XMOS USB Audio 2.0:0000:1"
let clockFollow = AudioObjectPropertySelector(0x6C63_6673) // 'lcfs'

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let seconds = Int(arguments.first ?? "") ?? 60
let csvPath = arguments.count > 1 ? arguments[arguments.startIndex + 1] : nil
let openLoop = CommandLine.arguments.contains("--open")

/// 每隔多久量一次相位、更新一次速度
let interval = 0.5
/// 估計 DAC 速度用的時間窗
let rateWindow = 30.0
/// 相位誤差在多少秒內拉回來
let phaseTimeConstant = 20.0
/// 相位修正最多改變多少速度
let maxCorrectionPPM = 50.0
/// 量 DAC 速度多久之後才開始鎖
let warmup = 5.0

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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

func nominalRate(_ id: AudioDeviceID) -> Float64 {
    var a = address(kAudioDevicePropertyNominalSampleRate), rate = Float64(0), size = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &rate)
    return rate
}

func setNominalRate(_ id: AudioDeviceID, _ rate: Float64) {
    var a = address(kAudioDevicePropertyNominalSampleRate), value = rate
    AudioObjectSetPropertyData(id, &a, 0, nil, 8, &value)
}

@discardableResult
func setFollowScale(_ id: AudioDeviceID, _ scale: Double) -> OSStatus {
    var a = address(clockFollow)
    var value = scale as CFNumber
    return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<CFNumber>.size), $0) }
}

func followScale(_ id: AudioDeviceID) -> Double? {
    var a = address(clockFollow)
    var value: Unmanaged<CFPropertyList>?
    var size = UInt32(MemoryLayout<CFPropertyList>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == 0, let number = value?.takeRetainedValue() as? NSNumber else { return nil }
    return number.doubleValue
}

/// 把同一個主機時間換算成裝置的樣本位置
func sampleTime(_ id: AudioDeviceID, at host: UInt64) -> Double? {
    var input = AudioTimeStamp()
    input.mHostTime = host
    input.mFlags = .hostTimeValid
    var output = AudioTimeStamp()
    output.mFlags = .sampleTimeValid
    guard AudioDeviceTranslateTime(id, &input, &output) == 0 else { return nil }
    return output.mSampleTime
}

let silence: AudioDeviceIOBlock = { _, _, _, output, _ in
    for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
}

guard let bridge = device(uid: bridgeUID) else { print("Bridge not found"); exit(1) }
guard let dac = device(uid: dacUID) else { print("DAC not found"); exit(1) }
var followAddress = address(clockFollow)
guard AudioObjectHasProperty(bridge, &followAddress) else { print("Bridge driver has no clock follow property; install the new driver"); exit(1) }

let rate = nominalRate(dac)
if nominalRate(bridge) != rate {
    setNominalRate(bridge, rate)
    Thread.sleep(forTimeInterval: 1)
}
print("nominal: dac \(rate), bridge \(nominalRate(bridge)); mode \(openLoop ? "open (measure only)" : "locked")")

var procs = [(AudioDeviceID, AudioDeviceIOProcID)]()
let queue = DispatchQueue(label: "clocklock.io")
for id in [bridge, dac] {
    var proc: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&proc, id, queue, silence) == 0, let proc else { print("ioproc failed for \(id)"); exit(1) }
    AudioDeviceStart(id, proc)
    procs.append((id, proc))
}
signal(SIGINT) { _ in exit(130) }
Thread.sleep(forTimeInterval: 2)

var info = mach_timebase_info_data_t()
mach_timebase_info(&info)
func hostSeconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9 }

struct Point { let host: Double; let frames: Double }

/// 最小平方法的斜率
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
var csv = "t,phase,error,dacPPM,scalePPM\n"
let start = mach_absolute_time()
let steps = Int(Double(seconds) / interval)

for step in 0..<steps {
    let now = mach_absolute_time()
    if let b = sampleTime(bridge, at: now), let d = sampleTime(dac, at: now) {
        let t = hostSeconds(now)
        dacPoints.append(Point(host: t, frames: d))
        let phase = b - d
        phasePoints.append(Point(host: t, frames: phase))
        let window = dacPoints.drop { $0.host < t - rateWindow }
        let elapsed = t - hostSeconds(start)
        let dacPPM = window.count > 4 ? (slope(window) / rate - 1) * 1e6 : 0

        if !openLoop, elapsed >= warmup {
            if lockedPhase == nil { lockedPhase = phase }
            let error = phase - lockedPhase!
            // 相位超前就放慢，誤差在時間常數內拉回來
            let correction = max(-maxCorrectionPPM, min(maxCorrectionPPM, -error / phaseTimeConstant / rate * 1e6))
            scale = 1 + (dacPPM + correction) / 1e6
        }
        if !openLoop { setFollowScale(bridge, scale) }
        let error = lockedPhase.map { phase - $0 } ?? 0
        csv += String(format: "%.3f,%.3f,%.3f,%.3f,%.3f\n", elapsed, phase, error, dacPPM, (scale - 1) * 1e6)
        if step % Int(10 / interval) == 0 {
            print(String(format: "%6.0f s  phase error %+8.2f frames  dac %+7.2f ppm  bridge scale %+7.2f ppm", elapsed, error, dacPPM, (scale - 1) * 1e6))
            fflush(stdout)
        }
    }
    Thread.sleep(forTimeInterval: interval)
}

let readBack = followScale(bridge)
for (id, proc) in procs { AudioDeviceStop(id, proc); AudioDeviceDestroyIOProcID(id, proc) }
if let csvPath { try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8) }

// 鎖定後的相位：前 60 秒當作收斂期，之後看偏移的斜率與最大值
let lockStart = hostSeconds(start) + warmup + 60
let settled = phasePoints.filter { $0.host >= lockStart }
if settled.count > 10 {
    let base = openLoop ? settled.first!.frames : (lockedPhase ?? 0)
    let errors = settled.map { $0.frames - base }
    let drift = slope(settled[...])
    print(String(format: "after settling: phase drift %+.4f frames/s (%+.3f ppm), error max %.2f, rms %.2f frames",
                 drift, drift / rate * 1e6, errors.map(abs).max()!, sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))))
}
print("driver read-back scale: \(readBack.map { String(format: "%+.2f ppm", ($0 - 1) * 1e6) } ?? "unavailable")")
