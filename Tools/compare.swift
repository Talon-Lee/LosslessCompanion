// 第 4 步的音質比對：bridge 錄下的 DAC 整數樣本和原始音檔逐樣本比對。
// 原始檔用 ExtAudioFile 解碼成 32-bit 整數（16/24-bit 會精確地左移到高位），
// 先找出兩邊對齊的位置，再比對重疊的每一個樣本。
// 用法：compare <capture.raw> <原始音檔>
import AudioToolbox
import Foundation

guard CommandLine.arguments.count >= 3 else { print("usage: compare <capture.raw> <reference file> [capture frame of reference frame 0]"); exit(2) }
let forcedOffset = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]).map { $0 * 2 } : nil
let captureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let referenceURL = URL(fileURLWithPath: CommandLine.arguments[2])

let captureData = try! Data(contentsOf: captureURL)
let capture: [Int32] = captureData.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }

func decode(_ url: URL) -> (samples: [Int32], rate: Double, bits: UInt32) {
    var file: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { print("cannot open \(url.path)"); exit(1) }
    defer { ExtAudioFileDispose(file) }
    var source = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source)
    var client = AudioStreamBasicDescription(mSampleRate: source.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                             mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                             mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
    var result = [Int32]()
    let chunk = 32768
    var buffer = [Int32](repeating: 0, count: chunk * 2)
    while true {
        var frames = UInt32(chunk)
        let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileRead(file, &frames, &list)
        }
        guard status == noErr else { print("decode error \(status)"); exit(1) }
        if frames == 0 { break }
        result.append(contentsOf: buffer[0..<Int(frames) * 2])
    }
    return (result, source.mSampleRate, source.mBitsPerChannel)
}

let decoded = decode(referenceURL)
let ref = decoded.samples
/// FLAC 的檔案格式不帶位元深度，用樣本裡最低的非零位元推算
let effectiveBits: UInt32 = {
    let combined = ref.reduce(Int32(0)) { $0 | $1 }
    return combined == 0 ? 32 : UInt32(32 - combined.trailingZeroBitCount)
}()
let reference = (samples: ref, rate: decoded.rate, bits: decoded.bits == 0 ? effectiveBits : min(decoded.bits, 32))
print("reference: \(ref.count / 2) frames, \(Int(reference.rate)) Hz, \(reference.bits)-bit")
let firstSound = capture.firstIndex { $0 != 0 } ?? capture.count
print("capture: \(capture.count / 2) frames, first sound at frame \(firstSound / 2)")

// 找原始檔第一段夠大聲的樣本，到錄音裡找完全相同的 256 個樣本
let window = 256
// 錨點放在錄到的那段中間附近：Music 開始播放時會淡入，開頭的樣本本來就不同
let capturedFrames = ((capture.lastIndex { $0 != 0 } ?? 0) - firstSound) / 2
let anchorStart = min(max(0, capturedFrames / 2), ref.count / 2 - 1) * 2
guard let anchor = stride(from: anchorStart, to: ref.count - window, by: 2).first(where: { abs(Int64(ref[$0])) > (1 << 24) }) else { print("reference is silent"); exit(1) }
var alignment: Int? = forcedOffset
var i = firstSound - firstSound % 2
while alignment == nil && i + window <= capture.count {
    if capture[i] == ref[anchor] && capture[i + 1] == ref[anchor + 1] {
        var same = true
        for k in 0..<window where capture[i + k] != ref[anchor + k] { same = false; break }
        if same { alignment = i - anchor; break }
    }
    i += 2
}

guard let offset = alignment else {
    // 對不上：可能版本不同或樣本被改過。用相關性找最接近的位置，估計音量比例
    print("NO EXACT ALIGNMENT: the reference window never appears unchanged in the capture")
    let probe = Array(ref[anchor..<min(ref.count, anchor + 44100 * 2)])
    var best = (score: -Double.infinity, offset: 0)
    let searchStart = max(0, firstSound - firstSound % 2)
    var j = searchStart
    while j + probe.count <= min(capture.count, searchStart + 44100 * 2 * 20) {
        var dot = 0.0
        for k in stride(from: 0, to: probe.count, by: 16) { dot += Double(capture[j + k]) * Double(probe[k]) }
        if dot > best.score { best = (dot, j - anchor) }
        j += 2
    }
    var sumRef = 0.0, sumCross = 0.0, maxDiff: Int64 = 0
    for k in 0..<probe.count {
        let c = Double(capture[anchor + best.offset + k]), r = Double(probe[k])
        sumRef += r * r; sumCross += c * r
        maxDiff = max(maxDiff, abs(Int64(capture[anchor + best.offset + k]) - Int64(probe[k])))
    }
    print(String(format: "best correlation at offset %d frames: gain %.6f (%.3f dB), max difference %lld (%.1f bits)",
                 best.offset / 2, sumCross / sumRef, 20 * log10(sumCross / sumRef), maxDiff, log2(Double(max(maxDiff, 1)))))
    exit(3)
}

// 逐樣本比對重疊的部分
let refStart = max(0, -offset), capStart = refStart + offset
// 錄音後段的靜音（餵完或播完之後）不算在比對範圍內
let lastSound = (capture.lastIndex { $0 != 0 } ?? 0) / 2 * 2 + 2
let overlap = max(0, min(ref.count - refStart, lastSound - capStart))
var mismatches = 0
var firstMismatch: Int?
var lowBitsSet = 0
let lowMask: Int32 = reference.bits < 32 ? Int32(truncatingIfNeeded: (Int64(1) << (32 - Int64(reference.bits))) - 1) : 0
for k in 0..<overlap {
    let c = capture[capStart + k]
    if c != ref[refStart + k] {
        mismatches += 1
        if firstMismatch == nil { firstMismatch = k }
    }
    if c & lowMask != 0 { lowBitsSet += 1 }
}
let refFramesCovered = overlap / 2
print("aligned: reference frame \(refStart / 2) = capture frame \(capStart / 2); compared \(refFramesCovered) frames (\(String(format: "%.1f", Double(refFramesCovered) / reference.rate)) s, \(String(format: "%.1f", 100 * Double(refFramesCovered) / Double(ref.count / 2)))% of the track)")
print("samples below the source's \(reference.bits)-bit resolution that are non-zero: \(lowBitsSet)")
// 每秒有幾個樣本不同，連續的秒數合併成一段
let rateFrames = Int(reference.rate)
var ranges = [(start: Int, end: Int, count: Int)]()
var second = 0
while second * rateFrames * 2 < overlap {
    let lo = second * rateFrames * 2, hi = min(overlap, lo + rateFrames * 2)
    var count = 0
    for k in lo..<hi where capture[capStart + k] != ref[refStart + k] { count += 1 }
    if count > 0 {
        if let last = ranges.last, last.end == second { ranges[ranges.count - 1] = (last.start, second + 1, last.count + count) }
        else { ranges.append((second, second + 1, count)) }
    }
    second += 1
}
for r in ranges.prefix(10) {
    print("  differs in reference seconds \(r.start + refStart / 2 / rateFrames)-\(r.end + refStart / 2 / rateFrames): \(r.count) samples")
}
if mismatches == 0 {
    print("BIT-PERFECT: all \(overlap) samples identical")
} else {
    let k = firstMismatch!
    print("MISMATCH: \(mismatches) of \(overlap) samples differ; first at reference frame \((refStart + k) / 2): capture \(capture[capStart + k]) vs reference \(ref[refStart + k])")
    exit(4)
}
