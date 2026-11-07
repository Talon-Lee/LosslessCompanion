// 第 4 步的對照組：不經過 Music，直接把音檔的樣本寫進 LosslessCompanion Bridge 的輸出端。
// 搭配 bridge 錄下 DAC 收到的樣本，再用 compare 比對，就能確認 Bridge 與橋接本身是否 Bit-Perfect。
// 16/24-bit 樣本轉成 Float32 是精確的。
// 用法：feed <音檔> <秒數>
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

guard CommandLine.arguments.count == 3, let seconds = Double(CommandLine.arguments[2]) else { print("usage: feed <file> <seconds>"); exit(2) }
let url = URL(fileURLWithPath: CommandLine.arguments[1])

var file: ExtAudioFileRef?
guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { print("cannot open"); exit(1) }
var source = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source)
var client = AudioStreamBasicDescription(mSampleRate: source.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                         mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                         mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                         mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
let totalFrames = Int(seconds * source.mSampleRate)
let samples = UnsafeMutablePointer<Float>.allocate(capacity: totalFrames * 2)
var loaded = 0
while loaded < totalFrames {
    var frames = UInt32(min(32768, totalFrames - loaded))
    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: frames * 8, mData: samples + loaded * 2))
    guard ExtAudioFileRead(file, &frames, &list) == noErr, frames > 0 else { break }
    loaded += Int(frames)
}
ExtAudioFileDispose(file)
print("loaded \(loaded) frames at \(Int(source.mSampleRate)) Hz")

var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var uid = "LosslessCompanionBridge_UID" as CFString
var bridge = AudioDeviceID(0)
size = 4
_ = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 8, $0, &size, &bridge) }
guard bridge != 0 else { print("Bridge not found"); exit(1) }

let position = Atomic<Int>(0)
let finished = Atomic<Bool>(false)
let total = loaded
let io: AudioDeviceIOBlock = { _, _, _, output, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    guard let first = buffers.first, let data = first.mData else { return }
    let frames = Int(first.mDataByteSize) / 8
    let out = data.assumingMemoryBound(to: Float.self)
    let start = position.load(ordering: .relaxed)
    let n = max(0, min(frames, total - start))
    if n > 0 { out.update(from: samples + start * 2, count: n * 2) }
    if n < frames { (out + n * 2).update(repeating: 0, count: (frames - n) * 2) }
    position.store(start + n, ordering: .relaxed)
    if start + n >= total { finished.store(true, ordering: .relaxed) }
}
var proc: AudioDeviceIOProcID?
guard AudioDeviceCreateIOProcIDWithBlock(&proc, bridge, DispatchQueue(label: "feed"), io) == 0, let proc else { print("ioproc failed"); exit(1) }
AudioDeviceStart(bridge, proc)
while !finished.load(ordering: .relaxed) { Thread.sleep(forTimeInterval: 0.2) }
Thread.sleep(forTimeInterval: 0.5)
AudioDeviceStop(bridge, proc)
AudioDeviceDestroyIOProcID(bridge, proc)
print("fed \(position.load(ordering: .relaxed)) frames")
