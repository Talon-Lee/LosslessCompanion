// 第 2 步：量 LosslessCompanion Bridge 與實體 DAC 的時脈差。
// 兩個裝置各跑一個只寫靜音的 IOProc，讓時脈運作；每秒讀一次各自的 (樣本時間, 主機時間)，
// 最後用線性回歸算出各自實際的取樣率，相差多少 ppm 就是兩個時脈之間的漂移。
// 不發出聲音，不改預設輸出；只在需要時把 Bridge 設成和 DAC 相同的取樣率。
// 用法：drift <秒數> [輸出 CSV 路徑]
import CoreAudio
import Foundation

let bridgeUID = "LosslessCompanionBridge_UID"
let dacUID = "AppleUSBAudioEngine:XMOS:XMOS USB Audio 2.0:0000:1"
let seconds = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 60
let csvPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
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

/// 只寫靜音，讓裝置的時脈持續運作
let silence: AudioDeviceIOBlock = { _, _, _, output, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
}

guard let bridge = device(uid: bridgeUID) else { print("Bridge not found"); exit(1) }
guard let dac = device(uid: dacUID) else { print("DAC not found"); exit(1) }

let rate = nominalRate(dac)
if nominalRate(bridge) != rate {
    setNominalRate(bridge, rate)
    Thread.sleep(forTimeInterval: 1)
}
print("nominal: dac \(rate), bridge \(nominalRate(bridge))")

var procs = [(AudioDeviceID, AudioDeviceIOProcID)]()
let queue = DispatchQueue(label: "drift.io")
for id in [bridge, dac] {
    var proc: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&proc, id, queue, silence) == 0, let proc else { print("ioproc failed for \(id)"); exit(1) }
    AudioDeviceStart(id, proc)
    procs.append((id, proc))
}
func stopAll() { for (id, proc) in procs { AudioDeviceStop(id, proc); AudioDeviceDestroyIOProcID(id, proc) } }
signal(SIGINT) { _ in exit(130) }
atexit { }

// 等時脈穩定
Thread.sleep(forTimeInterval: 2)

var info = mach_timebase_info_data_t()
mach_timebase_info(&info)
func hostSeconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9 }

struct Sample { let host: Double; let frames: Double }
var samples: [AudioDeviceID: [Sample]] = [bridge: [], dac: []]
var csv = "t,device,host,sampleTime\n"
for second in 0..<seconds {
    for id in [bridge, dac] {
        var time = AudioTimeStamp()
        guard AudioDeviceGetCurrentTime(id, &time) == 0 else { continue }
        let sample = Sample(host: hostSeconds(time.mHostTime), frames: time.mSampleTime)
        samples[id]!.append(sample)
        csv += "\(second),\(id == bridge ? "bridge" : "dac"),\(sample.host),\(sample.frames)\n"
    }
    if second % 60 == 59 { print("  \(second + 1) s"); fflush(stdout) }
    Thread.sleep(forTimeInterval: 1)
}
stopAll()
if let csvPath { try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8) }

/// 樣本時間對主機時間的斜率就是實際取樣率；殘差顯示時間戳記的抖動
func fit(_ points: [Sample]) -> (rate: Double, jitterFrames: Double) {
    let t0 = points[0].host, f0 = points[0].frames
    let xs = points.map { $0.host - t0 }, ys = points.map { $0.frames - f0 }
    let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    let slope = sxy / sxx, intercept = my - slope * mx
    let residuals = zip(xs, ys).map { $1 - (intercept + slope * $0) }
    return (slope, sqrt(residuals.reduce(0) { $0 + $1 * $1 } / n))
}

let b = fit(samples[bridge]!), d = fit(samples[dac]!)
let ppm = (d.rate / b.rate - 1) * 1e6
print(String(format: "bridge: %.4f Hz (%+.2f ppm vs nominal), jitter %.2f frames", b.rate, (b.rate / rate - 1) * 1e6, b.jitterFrames))
print(String(format: "dac:    %.4f Hz (%+.2f ppm vs nominal), jitter %.2f frames", d.rate, (d.rate / rate - 1) * 1e6, d.jitterFrames))
print(String(format: "drift dac vs bridge: %+.2f ppm = %+.1f frames per minute = %+.0f frames per hour", ppm, (d.rate - b.rate) * 60, (d.rate - b.rate) * 3600))
