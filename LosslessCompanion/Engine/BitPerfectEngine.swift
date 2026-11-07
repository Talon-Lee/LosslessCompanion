//
//  BitPerfectEngine.swift
//  LosslessCompanion
//
//  本地音檔 Bit-Perfect 播放引擎：
//  檔案 → ExtAudioFile 解碼 → 無鎖環形緩衝 → IOProc → 獨佔的 DAC。
//  全程不重取樣、不混音、不調音量；每首播完以 MD5 比對解碼與輸出資料。
//

import AudioToolbox
import CoreAudio
import CryptoKit
import Foundation
import Synchronization

// MARK: - Errors

enum BitPerfectError: LocalizedError {
    case cannotOpen(OSStatus)
    case lossySource(String)
    case floatSource
    case unsupportedBitDepth(Int)
    case unsupportedChannels(Int)
    case unsupportedSampleRate(Double)
    case bitDepthExceedsDevice(source: Int, device: Int)
    case deviceNotFound
    case deviceBusy(pid_t)
    case deviceUnsupported(String)
    case coreAudio(String, OSStatus)
    case decodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let status):
            return String(localized: "無法開啟音檔（\(String(status))）")
        case .lossySource(let codec):
            return String(localized: "\(codec) 是有損格式，不列入 Bit-Perfect 播放")
        case .floatSource:
            return String(localized: "浮點 PCM 音檔無法以整數格式無損輸出")
        case .unsupportedBitDepth(let bits):
            return String(localized: "不支援 \(bits)-bit 音檔")
        case .unsupportedChannels(let channels):
            return String(localized: "目前只支援立體聲音檔（此檔案為 \(channels) 聲道）")
        case .unsupportedSampleRate(let rate):
            return String(localized: "DAC 不支援 \(Format.sampleRate(rate))，已拒絕播放（不做重取樣）")
        case .bitDepthExceedsDevice(let source, let device):
            return String(localized: "音檔為 \(source)-bit，超過 DAC 的 \(device)-bit，無法無損輸出")
        case .deviceNotFound:
            return String(localized: "找不到輸出裝置")
        case .deviceBusy(let pid):
            return String(localized: "DAC 正被其他程式獨佔（PID \(String(pid))）")
        case .deviceUnsupported(let reason):
            return String(localized: "此輸出裝置不適用：\(reason)")
        case .coreAudio(let action, let status):
            return String(localized: "Core Audio 錯誤：\(action)（\(String(status))）")
        case .decodeFailed(let status):
            return String(localized: "解碼失敗（\(String(status))）")
        }
    }
}

// MARK: - Source file

struct AudioSourceFormat: Equatable {
    let sampleRate: Double
    let bitsPerSample: Int
    let channels: Int
    let frameCount: Int64

    var description: String {
        let khz = sampleRate / 1000
        let rate = khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        return "\(rate) kHz / \(bitsPerSample)-bit"
    }
}

/// 解碼成 32-bit 高位對齊整數（16-bit 樣本 << 16、24-bit 樣本 << 8），其餘位元為 0
final class PCMFileReader {
    let format: AudioSourceFormat
    let embeddedMD5: Data?
    private let file: ExtAudioFileRef

    init(url: URL) throws {
        var opened: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &opened)
        guard status == noErr, let file = opened else { throw BitPerfectError.cannotOpen(status) }
        self.file = file

        do {
            var fileFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: fileFormat))
            var result = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
            guard result == noErr else { throw BitPerfectError.cannotOpen(result) }

            let bits = try Self.sourceBits(of: fileFormat)
            guard bits <= 32 else { throw BitPerfectError.unsupportedBitDepth(bits) }
            guard fileFormat.mChannelsPerFrame == 2 else {
                throw BitPerfectError.unsupportedChannels(Int(fileFormat.mChannelsPerFrame))
            }

            var frames: Int64 = 0
            size = UInt32(MemoryLayout.size(ofValue: frames))
            result = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
            guard result == noErr else { throw BitPerfectError.cannotOpen(result) }

            var client = AudioStreamBasicDescription(
                mSampleRate: fileFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            result = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                             UInt32(MemoryLayout.size(ofValue: client)), &client)
            guard result == noErr else { throw BitPerfectError.cannotOpen(result) }

            self.format = AudioSourceFormat(sampleRate: fileFormat.mSampleRate, bitsPerSample: bits,
                                            channels: 2, frameCount: frames)
            self.embeddedMD5 = fileFormat.mFormatID == kAudioFormatFLAC ? Self.flacStreamMD5(url: url) : nil
        }
        catch {
            ExtAudioFileDispose(file)
            throw error
        }
    }

    deinit {
        ExtAudioFileDispose(file)
    }

    /// 回傳實際讀到的 frame 數，0 代表檔案結束
    func read(into destination: UnsafeMutablePointer<Int32>, frames: Int) throws -> Int {
        var count = UInt32(frames)
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: destination)
        )
        let status = ExtAudioFileRead(file, &count, &list)
        guard status == noErr else { throw BitPerfectError.decodeFailed(status) }
        return Int(count)
    }

    func seek(toFrame frame: Int64) throws {
        let status = ExtAudioFileSeek(file, frame)
        guard status == noErr else { throw BitPerfectError.decodeFailed(status) }
    }

    private static func sourceBits(of format: AudioStreamBasicDescription) throws -> Int {
        switch format.mFormatID {
        case kAudioFormatLinearPCM:
            if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 { throw BitPerfectError.floatSource }
            return Int(format.mBitsPerChannel)
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            switch format.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: throw BitPerfectError.unsupportedBitDepth(0)
            }
        case kAudioFormatMPEGLayer3:
            throw BitPerfectError.lossySource("MP3")
        case kAudioFormatMPEG4AAC:
            throw BitPerfectError.lossySource("AAC")
        default:
            throw BitPerfectError.lossySource(String(localized: "此格式"))
        }
    }

    /// 取出 FLAC STREAMINFO 內，編碼器寫入的原始 PCM MD5
    private static func flacStreamMD5(url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let offset = FLACHeader.metadataOffset(in: handle),
              (try? handle.seek(toOffset: offset)) != nil,
              let block = try? handle.read(upToCount: 42), block.count == 42,
              block[block.startIndex + 4] & 0x7F == 0 else { return nil }

        let md5 = block.suffix(16)
        return md5.allSatisfy({ $0 == 0 }) ? nil : Data(md5)
    }
}

enum FLACHeader {
    /// fLaC 標記的位置；部分檔案前面有 ID3 標籤
    static func metadataOffset(in handle: FileHandle) -> UInt64? {
        guard (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 10), head.count == 10 else { return nil }
        var offset: UInt64 = 0
        if head.prefix(3).elementsEqual("ID3".utf8) {
            offset = 10 + head.suffix(4).reduce(UInt64(0)) { ($0 << 7) | UInt64($1 & 0x7F) }
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let marker = try? handle.read(upToCount: 4),
              marker.elementsEqual("fLaC".utf8) else { return nil }
        return offset
    }
}

// MARK: - MD5 over PCM

/// 依 FLAC 規範計算 MD5：有號、小端序、每樣本 (bits + 7) / 8 位元組
struct PCMHasher {
    private var md5 = Insecure.MD5()
    private let bytesPerSample: Int
    private let shift: Int32
    private var scratch = [UInt8]()
    private(set) var sampleCount: Int64 = 0

    init(bitsPerSample: Int) {
        bytesPerSample = (bitsPerSample + 7) / 8
        shift = Int32(32 - bitsPerSample)
    }

    mutating func update(_ samples: UnsafeBufferPointer<Int32>) {
        let needed = samples.count * bytesPerSample
        if scratch.count < needed { scratch = [UInt8](repeating: 0, count: needed) }
        let bytesPerSample = self.bytesPerSample
        let shift = self.shift
        scratch.withUnsafeMutableBufferPointer { out in
            var index = 0
            for sample in samples {
                var value = sample >> shift
                for _ in 0..<bytesPerSample {
                    out[index] = UInt8(truncatingIfNeeded: value)
                    value >>= 8
                    index += 1
                }
            }
        }
        scratch.withUnsafeBytes { md5.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<needed])) }
        sampleCount += Int64(samples.count)
    }

    func finalized() -> Data {
        Data(md5.finalize())
    }
}

// MARK: - Lock-free ring

/// 單一寫入者、單一讀取者。讀取端在即時音訊執行緒上，不可配置記憶體或上鎖
final class SampleRing {
    private let storage: UnsafeMutablePointer<Int32>
    private let capacity: Int
    private let mask: Int
    private let readPosition = Atomic<Int>(0)
    private let writePosition = Atomic<Int>(0)

    init(minimumCapacity: Int) {
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    var freeSpace: Int {
        capacity - (writePosition.load(ordering: .relaxed) - readPosition.load(ordering: .acquiring))
    }

    var availableSamples: Int {
        writePosition.load(ordering: .acquiring) - readPosition.load(ordering: .relaxed)
    }

    /// 空間不足時不寫入任何資料並回傳 false
    @discardableResult
    func write(_ source: UnsafePointer<Int32>, count: Int) -> Bool {
        guard count <= freeSpace else { return false }
        let position = writePosition.load(ordering: .relaxed)
        let start = position & mask
        let first = min(count, capacity - start)
        (storage + start).update(from: source, count: first)
        storage.update(from: source + first, count: count - first)
        writePosition.store(position + count, ordering: .releasing)
        return true
    }

    func read(into destination: UnsafeMutablePointer<Int32>, count: Int) -> Int {
        let position = readPosition.load(ordering: .relaxed)
        let readable = min(count, writePosition.load(ordering: .acquiring) - position)
        guard readable > 0 else { return 0 }
        let start = position & mask
        let first = min(readable, capacity - start)
        destination.update(from: storage + start, count: first)
        (destination + first).update(from: storage, count: readable - first)
        readPosition.store(position + readable, ordering: .releasing)
        return readable
    }
}

// MARK: - Realtime render

enum OutputPath: String {
    /// 不可混音的整數格式：IOProc 的資料直接交給驅動，HAL 不做轉換
    case directInteger = "Direct Integer"
    /// 裝置不提供整數格式時退回 32-bit 浮點；24-bit 以內仍可精確表示
    case float32 = "Float32"
}

/// 只在 IOProc 中執行 render，所有方法都不得配置記憶體或上鎖
final class RenderCore {
    let ring: SampleRing
    let tap: SampleRing
    let path: OutputPath

    let isPaused = Atomic<Bool>(false)
    let decodeFinished = Atomic<Bool>(false)
    let drained = Atomic<Bool>(false)
    let underruns = Atomic<Int>(0)
    let tapDrops = Atomic<Int>(0)
    let renderedSamples = Atomic<Int>(0)
    /// 輸出到這裡就結束：緩衝裡後面的樣本屬於已經從佇列換掉的曲目
    let endSample = Atomic<Int>(.max)

    private var leadInSamples: Int
    private let scale: Float = 1.0 / 2147483648.0

    init(ring: SampleRing, tap: SampleRing, path: OutputPath, leadInSamples: Int) {
        self.ring = ring
        self.tap = tap
        self.path = path
        self.leadInSamples = leadInSamples
    }

    func render(into output: UnsafeMutableRawPointer, byteCount: Int) {
        let total = byteCount / MemoryLayout<Int32>.stride
        let samples = output.bindMemory(to: Int32.self, capacity: total)

        if isPaused.load(ordering: .relaxed) || drained.load(ordering: .relaxed) {
            samples.update(repeating: 0, count: total)
            return
        }

        var written = 0
        if leadInSamples > 0 {
            let silence = min(leadInSamples, total)
            samples.update(repeating: 0, count: silence)
            leadInSamples -= silence
            written = silence
        }

        let start = samples + written
        let wanted = total - written
        let remaining = endSample.load(ordering: .acquiring) - renderedSamples.load(ordering: .relaxed)
        let count = wanted > 0 ? ring.read(into: start, count: max(0, min(wanted, remaining))) : 0

        if count > 0 {
            if path == .float32 {
                for index in 0..<count {
                    start[index] = Int32(bitPattern: (Float(start[index]) * scale).bitPattern)
                }
            }
            if !tap.write(start, count: count) {
                tapDrops.add(1, ordering: .relaxed)
            }
            renderedSamples.add(count, ordering: .relaxed)
        }

        if count < wanted {
            (start + count).update(repeating: 0, count: wanted - count)
            if count >= remaining || (decodeFinished.load(ordering: .acquiring) && ring.availableSamples == 0) {
                drained.store(true, ordering: .releasing)
            }
            else {
                underruns.add(1, ordering: .relaxed)
            }
        }
    }
}

private let bitPerfectIOProc: AudioDeviceIOProc = { _, _, _, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let buffer = outputData.pointee.mBuffers
    if outputData.pointee.mNumberBuffers > 0, let data = buffer.mData {
        Unmanaged<RenderCore>.fromOpaque(clientData)._withUnsafeGuaranteedRef {
            $0.render(into: data, byteCount: Int(buffer.mDataByteSize))
        }
    }
    return noErr
}

// MARK: - Decode and verify pipelines

/// 連續樣本流中的一首歌；可變欄位都由 PlaybackSession.stateLock 保護
private final class TrackSegment {
    let queueIndex: Int
    let url: URL
    let format: AudioSourceFormat
    let startFrame: Int64
    let embeddedMD5: Data?
    let firstSample: Int64
    var endSample: Int64?
    var decodedMD5: Data?
    var decodedSamples: Int64 = 0
    var decodeError: Error?

    init(queueIndex: Int, url: URL, reader: PCMFileReader, startFrame: Int64, firstSample: Int64) {
        self.queueIndex = queueIndex
        self.url = url
        format = reader.format
        embeddedMD5 = reader.embeddedMD5
        self.startFrame = startFrame
        self.firstSample = firstSample
    }
}

/// 一段連續播放的解碼與驗證。同取樣率的下一首緊接著寫入同一條緩衝，因此不留空隙。
/// 不接觸音訊裝置，測試工具可直接呼叫 render 做離線驗證
final class PlaybackSession {
    let core: RenderCore

    private let firstIndex: Int
    private let firstStartFrame: Int64
    private let sampleRate: Double
    private let maxBits: Int
    private let overloads: () -> Int
    /// 輸出裝置會沿用到下一段播放，計數不會歸零，每段只算自己開始之後的
    private let overloadsAtStart: Int

    private var firstReader: PCMFileReader?
    private let shouldStop = Atomic<Bool>(false)
    private let threads = DispatchGroup()
    private let stateLock = NSLock()
    /// 以下由 stateLock 保護
    private var urls: [URL]
    private var segments = [TrackSegment]()
    private var finishedReports = [PlaybackReport]()
    private var pendingIndex: Int?
    private var decodeEnded = false
    /// 緩衝裡的曲目被換掉了，解碼端不再往下讀，輸出停在 core.endSample
    private let isCut = Atomic<Bool>(false)

    private static let chunkFrames = 8192

    init(urls: [URL], index: Int, startFrame: Int64, path: OutputPath, maxBits: Int,
         leadInSamples: Int, overloads: @escaping () -> Int) throws {
        self.urls = urls
        firstIndex = index
        firstStartFrame = startFrame
        self.maxBits = maxBits
        self.overloads = overloads
        overloadsAtStart = overloads()

        let reader = try PCMFileReader(url: urls[index])
        if startFrame > 0 { try reader.seek(toFrame: startFrame) }
        firstReader = reader
        sampleRate = reader.format.sampleRate

        let secondSamples = Int(sampleRate) * 2
        core = RenderCore(ring: SampleRing(minimumCapacity: secondSamples * 4),
                          tap: SampleRing(minimumCapacity: secondSamples * 4),
                          path: path,
                          leadInSamples: leadInSamples)
    }

    func startPipelines() {
        spawn("BitPerfect.decode", qos: .userInitiated) { [self] in decodeLoop() }
        spawn("BitPerfect.verify", qos: .utility) { [self] in verifyLoop() }
    }

    /// 等解碼端先填好至少一秒資料，避免一開始就 underrun
    func waitForPrefill(timeout: TimeInterval = 3) {
        let target = Int(sampleRate) * 2
        let deadline = Date().addingTimeInterval(timeout)
        while core.ring.availableSamples < target,
              !core.decodeFinished.load(ordering: .acquiring),
              Date() < deadline {
            usleep(5_000)
        }
    }

    func stopPipelines() {
        shouldStop.store(true, ordering: .releasing)
        threads.wait()
    }

    /// 取走已完整輸出的曲目報告
    func takeFinishedReports() -> [PlaybackReport] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let reports = finishedReports
        finishedReports.removeAll()
        return reports
    }

    /// 無法接在同一條緩衝時，下一首的佇列位置
    var indexAfterDrain: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingIndex
    }

    /// 換成新的佇列，相同位置的曲目必須是已經在播的那些。解碼還沒走到的部分直接換掉就能無縫接上；
    /// 被換掉的曲目已經進緩衝時，輸出停在最後一首沒變的歌結尾，再由引擎從 indexAfterDrain 另開一段。
    /// 按下的瞬間剛好換歌時，結尾已經過去，目前的聲音會立刻停止，順序仍然正確
    func updateQueue(_ updated: [URL]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let kept = zip(urls, updated).prefix { $0.0 == $0.1 }.count
        urls = updated
        if let stale = segments.firstIndex(where: { $0.queueIndex >= kept }) {
            core.endSample.store(Int(segments[stale].firstSample), ordering: .releasing)
            segments.removeSubrange(stale...)
            isCut.store(true, ordering: .releasing)
        }
        else if !decodeEnded && !isCut.load(ordering: .relaxed) {
            return
        }
        let next = segments.last.map { $0.queueIndex + 1 } ?? min(kept, pendingIndex ?? kept)
        pendingIndex = next < updated.count ? next : nil
    }

    /// 目前聽到的位置，以已送出的樣本數換算
    func position() -> (queueIndex: Int, frame: Int64, format: AudioSourceFormat)? {
        let rendered = Int64(core.renderedSamples.load(ordering: .relaxed))
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let segment = segments.last(where: { $0.firstSample <= rendered }) else { return nil }
        return (segment.queueIndex, segment.startFrame + (rendered - segment.firstSample) / 2, segment.format)
    }

    private func spawn(_ name: String, qos: QualityOfService, _ body: @escaping () -> Void) {
        threads.enter()
        let group = threads
        let thread = Thread {
            body()
            group.leave()
        }
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
    }

    private func decodeLoop() {
        let chunkSamples = Self.chunkFrames * 2
        let buffer = UnsafeMutablePointer<Int32>.allocate(capacity: chunkSamples)
        defer { buffer.deallocate() }

        var next = firstSegment()
        var cursor: Int64 = 0
        while let (segment, reader) = next {
            guard decode(reader, into: segment, cursor: &cursor, buffer: buffer) else { break }
            next = nextSegment(after: segment.queueIndex, firstSample: cursor)
        }
        core.decodeFinished.store(true, ordering: .releasing)
    }

    private func firstSegment() -> (TrackSegment, PCMFileReader)? {
        guard let reader = firstReader else { return nil }
        firstReader = nil
        stateLock.lock()
        defer { stateLock.unlock() }
        let segment = TrackSegment(queueIndex: firstIndex, url: urls[firstIndex], reader: reader,
                                   startFrame: firstStartFrame, firstSample: 0)
        segments.append(segment)
        return (segment, reader)
    }

    /// 下一首能接在同一條緩衝就開始新的一段，否則記下來讓引擎另開一段。
    /// 開檔時不持有鎖，佇列可能在這期間改變，所以開好後要再確認一次
    private func nextSegment(after index: Int, firstSample: Int64) -> (TrackSegment, PCMFileReader)? {
        let nextIndex = index + 1

        func url() -> URL? {
            urls.indices.contains(nextIndex) && !isCut.load(ordering: .relaxed) ? urls[nextIndex] : nil
        }

        while true {
            stateLock.lock()
            let candidate = url()
            if candidate == nil { decodeEnded = true }
            stateLock.unlock()
            guard let candidate else { return nil }

            let reader = try? PCMFileReader(url: candidate)

            stateLock.lock()
            defer { stateLock.unlock() }
            guard url() == candidate else { continue }
            if let reader, reader.format.sampleRate == sampleRate, reader.format.bitsPerSample <= maxBits {
                let segment = TrackSegment(queueIndex: nextIndex, url: candidate, reader: reader,
                                           startFrame: 0, firstSample: firstSample)
                segments.append(segment)
                return (segment, reader)
            }
            pendingIndex = nextIndex
            decodeEnded = true
            return nil
        }
    }

    private var shouldAbandonDecoding: Bool {
        shouldStop.load(ordering: .acquiring) || isCut.load(ordering: .acquiring)
    }

    /// 回傳 false 代表被要求停止。其餘情況（包含解碼失敗）都會寫入 endSample，
    /// 而且一定在下一首的資料進入緩衝之前，驗證端才能正確切分曲目
    private func decode(_ reader: PCMFileReader, into segment: TrackSegment,
                        cursor: inout Int64, buffer: UnsafeMutablePointer<Int32>) -> Bool {
        var hasher = PCMHasher(bitsPerSample: segment.format.bitsPerSample)
        var failure: Error?

        decoding: while true {
            if shouldAbandonDecoding { return false }
            do {
                let frames = try reader.read(into: buffer, frames: Self.chunkFrames)
                if frames == 0 { break }
                let count = frames * 2
                hasher.update(UnsafeBufferPointer(start: buffer, count: count))
                while !core.ring.write(buffer, count: count) {
                    if shouldAbandonDecoding { return false }
                    usleep(10_000)
                }
                cursor += Int64(count)
            }
            catch {
                failure = error
                break decoding
            }
        }

        stateLock.lock()
        segment.decodedSamples = hasher.sampleCount
        segment.decodeError = failure
        if failure == nil { segment.decodedMD5 = hasher.finalized() }
        segment.endSample = cursor
        stateLock.unlock()
        return true
    }

    /// 讀回 IOProc 實際寫出的樣本，逐首計算 MD5 並和解碼結果比對
    private func verifyLoop() {
        let chunkSamples = Self.chunkFrames * 2
        let buffer = UnsafeMutablePointer<Int32>.allocate(capacity: chunkSamples)
        defer { buffer.deallocate() }

        let isFloat = core.path == .float32
        var position: Int64 = 0
        var segmentIndex = 0
        var hasher: PCMHasher?
        var reportedUnderruns = 0
        var reportedOverloads = overloadsAtStart

        func currentSegment() -> (segment: TrackSegment, end: Int64?)? {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard segmentIndex < segments.count else { return nil }
            let segment = segments[segmentIndex]
            return (segment, segment.endSample)
        }

        func finishSegment(_ segment: TrackSegment) {
            let underruns = core.underruns.load(ordering: .relaxed)
            let overloadTotal = overloads()
            let outputMD5 = hasher?.finalized()
            let outputSamples = hasher?.sampleCount ?? 0
            hasher = nil
            segmentIndex += 1

            stateLock.lock()
            finishedReports.append(PlaybackReport(
                queueIndex: segment.queueIndex,
                url: segment.url,
                format: segment.format,
                path: core.path,
                startFrame: segment.startFrame,
                embeddedMD5: segment.embeddedMD5,
                decodedMD5: segment.decodedMD5,
                outputMD5: outputMD5,
                decodedSamples: segment.decodedSamples,
                outputSamples: outputSamples,
                underruns: underruns - reportedUnderruns,
                overloads: overloadTotal - reportedOverloads,
                tapDrops: core.tapDrops.load(ordering: .relaxed),
                decodeError: segment.decodeError
            ))
            stateLock.unlock()
            reportedUnderruns = underruns
            reportedOverloads = overloadTotal
        }

        func finishCompletedSegments() {
            while let current = currentSegment(), let end = current.end, end == position {
                finishSegment(current.segment)
            }
        }

        while true {
            finishCompletedSegments()
            let count = core.tap.read(into: buffer, count: chunkSamples)
            if count == 0 {
                let finished = core.drained.load(ordering: .acquiring) || shouldStop.load(ordering: .acquiring)
                if finished && core.tap.availableSamples == 0 {
                    finishCompletedSegments()
                    break
                }
                usleep(10_000)
                continue
            }

            if isFloat {
                for index in 0..<count {
                    let sample = Float(bitPattern: UInt32(bitPattern: buffer[index]))
                    buffer[index] = Int32(sample * 2147483648.0)
                }
            }

            // 樣本進到 tap 時，前一首的 endSample 一定已寫入，所以讀完才取結尾位置
            var offset = 0
            while offset < count, let current = currentSegment() {
                let remaining = Int64(count - offset)
                let take = current.end.map { min(remaining, $0 - position) } ?? remaining
                if hasher == nil { hasher = PCMHasher(bitsPerSample: current.segment.format.bitsPerSample) }
                hasher?.update(UnsafeBufferPointer(start: buffer + offset, count: Int(take)))
                position += take
                offset += Int(take)
                finishCompletedSegments()
            }
        }
    }
}

struct PlaybackReport {
    let queueIndex: Int
    let url: URL
    let format: AudioSourceFormat
    let path: OutputPath
    let startFrame: Int64
    let embeddedMD5: Data?
    let decodedMD5: Data?
    let outputMD5: Data?
    let decodedSamples: Int64
    let outputSamples: Int64
    let underruns: Int
    let overloads: Int
    let tapDrops: Int
    let decodeError: Error?

    /// 解碼結果與檔案內建 MD5 相符；非 FLAC、檔案未寫入 MD5 或從中途開始時為 nil
    var decoderMatchesFile: Bool? {
        guard startFrame == 0, let embeddedMD5, let decodedMD5 else { return nil }
        return embeddedMD5 == decodedMD5
    }

    /// 播到曲目結尾，且送到 IOProc 的資料和解碼結果逐位元組相同，過程沒有中斷
    var isBitPerfect: Bool {
        decodeError == nil
            && decoderMatchesFile != false
            && decodedMD5 != nil
            && decodedMD5 == outputMD5
            && decodedSamples == outputSamples
            && decodedSamples == (format.frameCount - startFrame) * 2
            && underruns == 0
            && overloads == 0
            && tapDrops == 0
    }
}

// MARK: - Exclusive device

/// 裝置某個音量控制原本的值，還原時用
struct DeviceVolume: Equatable {
    let element: AudioObjectPropertyElement
    let value: Float32
}

struct DeviceCapabilities: Equatable {
    let sampleRates: Set<Double>
    let maxBits: Int

    func canPlay(sampleRate: Double, bitsPerSample: Int) -> Bool {
        sampleRates.contains(sampleRate) && bitsPerSample <= maxBits
    }
}

enum AudioDeviceLookup {
    static func defaultOutputUID() -> String? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return nil
        }
        return uid(of: device)
    }

    static func uid(of device: AudioDeviceID) -> String? {
        var address = propertyAddress(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func device(forUID uid: String) -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

private func propertyAddress(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// 每台 DAC 各自的獨佔設定
struct OutputOptions: Codable, Hashable {
    /// DAC 切換時鐘後需要時間鎖定，開頭先送這麼久的靜音以免吃掉第一個音
    var lockInSeconds = OutputOptions.defaultLockIn
    /// 獨佔期間把裝置音量固定在 100%，交還時還原
    var forcesMaxVolume = false

    static let defaultLockIn: TimeInterval = 0.25
    static let lockInChoices: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2]
}

/// 取得裝置獨佔權並維持到播放結束；Hog Mode 寫入是 Toggle，因此每次都先確認持有者
final class ExclusiveOutput {
    let device: AudioDeviceID
    private(set) var targetRate: Double
    private(set) var path: OutputPath = .float32
    /// 目前的輸出格式能無損容納的最大位元數
    private(set) var maxBits = 24

    private let stream: AudioStreamID
    private let originalRate: Double
    private let originalPhysicalFormat: AudioStreamBasicDescription
    private var ownsHog = false
    private var changedPhysicalFormat = false
    private var ioProc: AudioDeviceIOProcID?
    /// 改成 100% 之前的音量，交還裝置時還原
    private var savedVolumes = [DeviceVolume]()

    /// 主音量加左右聲道；不同裝置只有其中幾個
    private static let volumeElements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private let overloadCount = Atomic<Int>(0)
    private var listeners = [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]()
    private let listenerQueue = DispatchQueue(label: "BitPerfect.deviceListeners")

    var overloads: Int { overloadCount.load(ordering: .relaxed) }

    /// 裝置被拔除、取樣率遭外部更動或失去獨佔權時觸發
    var onInterrupted: ((String) -> Void)?

    init(deviceUID: String, rate: Double, bitsPerSample: Int, forcesMaxVolume: Bool = false) throws {
        guard let device = AudioDeviceLookup.device(forUID: deviceUID) else { throw BitPerfectError.deviceNotFound }
        self.device = device
        targetRate = rate

        let streams = Self.outputStreams(of: device)
        guard let firstStream = streams.first else { throw BitPerfectError.deviceUnsupported(String(localized: "沒有輸出串流")) }
        guard streams.count == 1 else { throw BitPerfectError.deviceUnsupported(String(localized: "僅支援單一輸出串流")) }
        stream = firstStream

        originalRate = Self.nominalRate(of: device)
        originalPhysicalFormat = try Self.format(of: stream, selector: kAudioStreamPropertyPhysicalFormat)
        guard originalPhysicalFormat.mChannelsPerFrame == 2 else {
            throw BitPerfectError.deviceUnsupported(String(localized: "目前僅支援雙聲道輸出"))
        }
        guard Self.supportedRates(of: device).contains(rate) else {
            throw BitPerfectError.unsupportedSampleRate(rate)
        }

        try acquireHog()
        do {
            try applyOutputFormat(bitsPerSample: bitsPerSample)
            installListeners()
            if forcesMaxVolume { forceMaxVolume() }
        }
        catch {
            release()
            throw error
        }
    }

    deinit {
        release()
    }

    /// 裝置自己的音量，有左右聲道時取較低的一邊；沒有音量控制的裝置回傳 nil
    static func volume(deviceUID: String) -> Float? {
        guard let device = AudioDeviceLookup.device(forUID: deviceUID) else { return nil }
        return volumeElements.compactMap { volume(of: device, element: $0) }.min()
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func volume(of device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setVolume(_ value: Float32, of device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(element)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private func forceMaxVolume() {
        savedVolumes = Self.raiseVolume(of: device)
    }

    private func restoreVolume() {
        Self.restore(savedVolumes, on: device)
        savedVolumes = []
    }

    /// 把裝置拉到最大，回傳被改動的值。串流不獨佔，由 App 自己呼叫
    static func raiseVolume(deviceUID: String) -> [DeviceVolume] {
        AudioDeviceLookup.device(forUID: deviceUID).map(raiseVolume(of:)) ?? []
    }

    static func restore(_ volumes: [DeviceVolume], deviceUID: String) {
        if let device = AudioDeviceLookup.device(forUID: deviceUID) { restore(volumes, on: device) }
    }

    /// 主音量和左右聲道通常是連動的，要先全部讀完再改，才記得住原本的值
    private static func raiseVolume(of device: AudioDeviceID) -> [DeviceVolume] {
        let original = volumeElements.compactMap { element in
            volume(of: device, element: element).map { DeviceVolume(element: element, value: $0) }
        }
        return original.filter { $0.value < 1 && setVolume(1, of: device, element: $0.element) }
    }

    private static func restore(_ volumes: [DeviceVolume], on device: AudioDeviceID) {
        volumes.forEach { _ = setVolume($0.value, of: device, element: $0.element) }
    }

    /// 可 Bit-Perfect 播放的規格，音樂庫據此過濾檢索結果
    static func capabilities(deviceUID: String) -> DeviceCapabilities? {
        guard let device = AudioDeviceLookup.device(forUID: deviceUID),
              let stream = outputStreams(of: device).first,
              let physical = try? format(of: stream, selector: kAudioStreamPropertyPhysicalFormat),
              let formats = try? availablePhysicalFormats(of: stream) else { return nil }
        let directBits = formats
            .filter(isDirectInteger)
            .map { Int($0.mBitsPerChannel) }
            .max() ?? 0
        return DeviceCapabilities(sampleRates: Set(supportedRates(of: device)),
                                  maxBits: max(directBits, min(Int(physical.mBitsPerChannel), 24)))
    }

    /// 不可混音的整數格式，而且 IOProc 能把 32-bit 高位對齊的樣本原樣寫入。
    /// 樣本填滿 32-bit 容器時沒有對齊可言，USB 裝置常標成 Packed，記憶體排列完全相同
    static func isDirectInteger(_ format: AudioStreamBasicDescription) -> Bool {
        let required = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonMixable
        guard format.mFormatFlags & required == required, format.mBytesPerFrame == 8 else { return false }
        return format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 || format.mBitsPerChannel == 32
    }

    /// 程式在整數模式下遭強制結束時，獨佔權會被系統收回，但裝置會停在不可混音格式，
    /// macOS 因此不再把它當成預設輸出。無人獨佔的裝置若處於此格式，一律改回可混音
    @discardableResult
    static func recoverStrandedDevices() -> Int {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return 0 }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return 0 }

        var recovered = 0
        for device in devices {
            var hogAddress = propertyAddress(kAudioDevicePropertyHogMode)
            var owner: pid_t = -1
            var hogSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(device, &hogAddress, 0, nil, &hogSize, &owner)
            guard owner == -1 else { continue }

            for stream in outputStreams(of: device) {
                guard var format = try? format(of: stream, selector: kAudioStreamPropertyPhysicalFormat),
                      format.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 else { continue }
                format.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
                var formatAddress = propertyAddress(kAudioStreamPropertyPhysicalFormat)
                if AudioObjectSetPropertyData(stream, &formatAddress, 0, nil,
                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format) == noErr {
                    recovered += 1
                }
            }
        }
        return recovered
    }

    /// 持續獨佔下切換到另一首歌的規格
    func reconfigure(rate: Double, bitsPerSample: Int) throws {
        stop()
        guard Self.supportedRates(of: device).contains(rate) else {
            throw BitPerfectError.unsupportedSampleRate(rate)
        }
        guard rate != targetRate || bitsPerSample > maxBits else { return }
        targetRate = rate
        try applyOutputFormat(bitsPerSample: bitsPerSample)
    }

    func start(core: RenderCore) throws {
        var proc: AudioDeviceIOProcID?
        let client = Unmanaged.passUnretained(core).toOpaque()
        var status = AudioDeviceCreateIOProcID(device, bitPerfectIOProc, client, &proc)
        guard status == noErr, let proc else { throw BitPerfectError.coreAudio(String(localized: "建立 IOProc"), status) }
        ioProc = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw BitPerfectError.coreAudio(String(localized: "啟動輸出"), status) }
    }

    func stop() {
        guard let proc = ioProc else { return }
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
        ioProc = nil
    }

    /// 依序停止輸出、還原取樣率與格式，最後才交還獨佔權。
    /// 一定要先改回取樣率才改回可混音格式：順序相反時，同一程序下次啟動輸出會逾時失敗
    func release() {
        stop()
        removeListeners()
        restoreVolume()
        guard ownsHog else { return }

        if Self.nominalRate(of: device) != originalRate {
            try? applySampleRate(originalRate)
        }
        if changedPhysicalFormat {
            var restored = originalPhysicalFormat
            restored.mSampleRate = originalRate
            _ = try? setPhysicalFormat(&restored)
            changedPhysicalFormat = false
        }
        if hogOwner() == getpid() {
            toggleHog()
        }
        ownsHog = false
    }

    private func acquireHog() throws {
        let owner = hogOwner()
        guard owner == -1 else { throw BitPerfectError.deviceBusy(owner) }
        waitForDeviceToGoIdle()
        let status = toggleHog()
        guard status == noErr, hogOwner() == getpid() else { throw BitPerfectError.coreAudio(String(localized: "取得獨佔"), status) }
        ownsHog = true
    }

    /// Apple Music 暫停後還要一點時間才真正停止輸出，等它停下來再接手，避免兩邊同時操作裝置
    private func waitForDeviceToGoIdle() {
        _ = waitUntil(timeout: 1.5) {
            var address = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(self.device, &address, 0, nil, &size, &running)
            return running == 0
        }
    }

    private func hogOwner() -> pid_t {
        var address = propertyAddress(kAudioDevicePropertyHogMode)
        var owner: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &owner)
        return owner
    }

    @discardableResult
    private func toggleHog() -> OSStatus {
        var address = propertyAddress(kAudioDevicePropertyHogMode)
        var pid = getpid()
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &pid)
    }

    private func applySampleRate(_ rate: Double) throws {
        guard Self.nominalRate(of: device) != rate else { return }
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw BitPerfectError.coreAudio(String(localized: "切換取樣率"), status) }
        guard waitUntil({ Self.nominalRate(of: self.device) == rate }) else {
            throw BitPerfectError.coreAudio(String(localized: "等待取樣率生效"), -1)
        }
    }

    /// 優先使用裝置提供的不可混音整數格式，條件見 isDirectInteger。
    /// 這類格式要寫到實體格式，虛擬格式會跟著改變；直接寫虛擬格式時 HAL 回傳成功但不生效。
    /// 實體格式已包含取樣率，因此一次設定完成，不再另外切換
    private func applyOutputFormat(bitsPerSample: Int) throws {
        let candidates = try Self.availablePhysicalFormats(of: stream).filter {
            $0.mFormatID == kAudioFormatLinearPCM
                && Self.isDirectInteger($0)
                && $0.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
                && $0.mChannelsPerFrame == 2
                && Int($0.mBitsPerChannel) >= bitsPerSample
                && ($0.mSampleRate == targetRate || $0.mSampleRate == 0)
        }

        if var chosen = candidates.min(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }) {
            chosen.mSampleRate = targetRate
            if (try? setPhysicalFormat(&chosen)) != nil {
                changedPhysicalFormat = true
                path = .directInteger
                maxBits = Int(chosen.mBitsPerChannel)
                return
            }
        }

        // 退回浮點：實體格式必須容納來源位元數，且 24-bit 以內才能由 Float32 精確表示
        try applySampleRate(targetRate)
        let deviceBits = Int(originalPhysicalFormat.mBitsPerChannel)
        guard bitsPerSample <= min(deviceBits, 24) else {
            throw BitPerfectError.bitDepthExceedsDevice(source: bitsPerSample, device: deviceBits)
        }
        path = .float32
        maxBits = min(deviceBits, 24)
    }

    private func setPhysicalFormat(_ format: inout AudioStreamBasicDescription) throws {
        var address = propertyAddress(kAudioStreamPropertyPhysicalFormat)
        let status = AudioObjectSetPropertyData(stream, &address, 0, nil,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format)
        guard status == noErr else { throw BitPerfectError.coreAudio(String(localized: "設定輸出格式"), status) }
        let expected = format
        let settled = waitUntil {
            guard let current = try? Self.format(of: self.stream, selector: kAudioStreamPropertyPhysicalFormat) else { return false }
            return current.mFormatFlags == expected.mFormatFlags
                && current.mBitsPerChannel == expected.mBitsPerChannel
                && current.mSampleRate == expected.mSampleRate
        }
        guard settled else { throw BitPerfectError.coreAudio(String(localized: "等待輸出格式生效"), -1) }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func installListeners() {
        addListener(kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self else { return }
            var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(self.device, &address, 0, nil, &size, &alive)
            if status != noErr || alive == 0 { self.onInterrupted?(String(localized: "DAC 已中斷連線")) }
        }
        addListener(kAudioDevicePropertyHogMode) { [weak self] in
            guard let self else { return }
            if self.ownsHog && self.hogOwner() != getpid() { self.onInterrupted?(String(localized: "失去 DAC 獨佔權")) }
        }
        addListener(kAudioDevicePropertyNominalSampleRate) { [weak self] in
            // 切換過程中 HAL 會短暫回報舊值，稍等後仍不同才算被外部更動
            self?.listenerQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.ownsHog && Self.nominalRate(of: self.device) != self.targetRate {
                    self.onInterrupted?(String(localized: "DAC 取樣率遭到外部更動"))
                }
            }
        }
        addListener(kAudioDeviceProcessorOverload) { [weak self] in
            self?.overloadCount.add(1, ordering: .relaxed)
        }
    }

    private func addListener(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = propertyAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
            listeners.append((address, block))
        }
    }

    private func removeListeners() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
        listeners.removeAll()
    }

    private static func outputStreams(of device: AudioDeviceID) -> [AudioStreamID] {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return [] }
        return streams
    }

    private static func nominalRate(of device: AudioDeviceID) -> Double {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func supportedRates(of device: AudioDeviceID) -> [Double] {
        var address = propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.filter({ $0.mMinimum == $0.mMaximum }).map(\.mMinimum)
    }

    private static func format(of stream: AudioStreamID, selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format)
        guard status == noErr else { throw BitPerfectError.coreAudio(String(localized: "讀取串流格式"), status) }
        return format
    }

    private static func availablePhysicalFormats(of stream: AudioStreamID) throws -> [AudioStreamBasicDescription] {
        var address = propertyAddress(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size)
        guard status == noErr else { throw BitPerfectError.coreAudio(String(localized: "讀取可用格式"), status) }
        var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                     count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &formats)
        guard status == noErr else { throw BitPerfectError.coreAudio(String(localized: "讀取可用格式"), status) }
        return formats.map(\.mFormat)
    }
}

// MARK: - Engine

/// 一個程序只能獨佔一次：釋放後要再獨佔，就要換一個程序，見 BitPerfectHelper.swift
final class BitPerfectEngine {
    var onTrackStarted: ((Int, AudioSourceFormat, OutputPath) -> Void)?
    var onTrackFinished: ((PlaybackReport) -> Void)?
    var onPosition: ((Int, Int64) -> Void)?
    /// 參數是佇列最後一首的位置
    var onQueueFinished: ((Int) -> Void)?
    var onInterrupted: ((String) -> Void)?
    /// 暫停太久而交還 DAC 後呼叫，參數是可以繼續播放的位置
    var onSuspended: ((Int, Int64) -> Void)?

    private let controlQueue = DispatchQueue(label: "BitPerfect.control")
    private let callbackQueue: DispatchQueue
    private var urls = [URL]()
    private var deviceUID = ""
    private var session: PlaybackSession?
    private var output: ExclusiveOutput?
    private var monitor: DispatchSourceTimer?
    private var drainedAt: Date?
    private var announcedIndex: Int?
    private var monitorTicks = 0
    private var isPaused = false
    private var pausedAt: Date?
    private var options = OutputOptions()

    /// 最後一批樣本還在 DAC 緩衝中，停止輸出前再等一下，避免切掉尾音
    private static let tailDelay: TimeInterval = 0.3
    /// 暫停太久就把 DAC 交還系統，其他 App 才不會一直被導向別的裝置
    private static let suspendDelay: TimeInterval = 30
    private static let seekSettleSeconds = 0.02

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    /// 開始獨佔播放佇列；已在獨佔時直接換佇列。失敗時不會留下獨佔狀態。
    /// 可能阻塞數百毫秒，請勿在主執行緒呼叫
    func play(urls: [URL], startIndex: Int = 0, startFrame: Int64 = 0, deviceUID: String, options: OutputOptions = OutputOptions()) throws {
        try controlQueue.sync {
            self.urls = urls
            self.deviceUID = deviceUID
            self.options = options
            isPaused = false
            pausedAt = nil
            do {
                try startSession(index: startIndex, startFrame: startFrame)
            }
            catch {
                teardown()
                throw error
            }
        }
    }

    func setPaused(_ paused: Bool) {
        controlQueue.sync {
            isPaused = paused
            pausedAt = paused ? Date() : nil
            session?.core.isPaused.store(paused, ordering: .relaxed)
        }
    }

    func seek(toFrame frame: Int64) throws {
        try controlQueue.sync {
            guard let current = session?.position() else { return }
            do {
                try startSession(index: current.queueIndex, startFrame: frame)
            }
            catch {
                teardown()
                throw error
            }
        }
    }

    func skip(toIndex index: Int) throws {
        try controlQueue.sync {
            guard urls.indices.contains(index) else { return }
            do {
                try startSession(index: index, startFrame: 0)
            }
            catch {
                teardown()
                throw error
            }
        }
    }

    /// 換掉 index 之後的曲目，正在播的歌不受影響
    func replaceUpcoming(after index: Int, with upcoming: [URL]) {
        controlQueue.sync {
            guard urls.indices.contains(index) else { return }
            urls = Array(urls[...index]) + upcoming
            session?.updateQueue(urls)
        }
    }

    /// 使用者主動停止；同步完成，返回時 DAC 已還原並釋放
    func stop() {
        controlQueue.sync { teardown() }
    }

    /// 重複使用已取得的獨佔權，切歌和拖動時 macOS 的預設輸出才不會來回跳動
    private func startSession(index: Int, startFrame: Int64) throws {
        stopSession()
        let format = try PCMFileReader(url: urls[index]).format

        let clockChanged: Bool
        let activeOutput: ExclusiveOutput
        if let output {
            clockChanged = output.targetRate != format.sampleRate
            try output.reconfigure(rate: format.sampleRate, bitsPerSample: format.bitsPerSample)
            activeOutput = output
        }
        else {
            activeOutput = try ExclusiveOutput(deviceUID: deviceUID, rate: format.sampleRate,
                                               bitsPerSample: format.bitsPerSample, forcesMaxVolume: options.forcesMaxVolume)
            activeOutput.onInterrupted = { [weak self] reason in self?.interrupt(reason) }
            output = activeOutput
            clockChanged = true
        }

        let leadIn = (clockChanged ? options.lockInSeconds : Self.seekSettleSeconds) * format.sampleRate
        let newSession = try PlaybackSession(urls: urls, index: index, startFrame: startFrame,
                                             path: activeOutput.path, maxBits: activeOutput.maxBits,
                                             leadInSamples: Int(leadIn) * 2,
                                             overloads: { [weak activeOutput] in activeOutput?.overloads ?? 0 })
        newSession.core.isPaused.store(isPaused, ordering: .relaxed)
        session = newSession
        newSession.startPipelines()
        newSession.waitForPrefill()
        try activeOutput.start(core: newSession.core)
        startMonitor()
    }

    private func startMonitor() {
        drainedAt = nil
        announcedIndex = nil
        monitorTicks = 0
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        monitor = timer
    }

    private func tick() {
        guard let session else { return }
        deliverReports(from: session)

        if let position = session.position() {
            if position.queueIndex != announcedIndex {
                announcedIndex = position.queueIndex
                let path = session.core.path
                callbackQueue.async { [weak self] in
                    self?.onTrackStarted?(position.queueIndex, position.format, path)
                }
            }
            monitorTicks += 1
            if monitorTicks % 5 == 0 {
                callbackQueue.async { [weak self] in self?.onPosition?(position.queueIndex, position.frame) }
            }
            if isPaused, let pausedAt, Date().timeIntervalSince(pausedAt) >= Self.suspendDelay {
                teardown()
                callbackQueue.async { [weak self] in self?.onSuspended?(position.queueIndex, position.frame) }
                return
            }
        }

        guard session.core.drained.load(ordering: .acquiring) else { return }
        if drainedAt == nil { drainedAt = Date() }
        guard let drainedAt, Date().timeIntervalSince(drainedAt) >= Self.tailDelay else { return }

        let nextIndex = session.indexAfterDrain
        stopSession()
        guard var index = nextIndex else {
            finishQueue()
            return
        }
        while index < urls.count {
            if (try? startSession(index: index, startFrame: 0)) != nil { return }
            index += 1
        }
        finishQueue()
    }

    private func deliverReports(from session: PlaybackSession) {
        let reports = session.takeFinishedReports()
        guard !reports.isEmpty else { return }
        callbackQueue.async { [weak self] in
            for report in reports { self?.onTrackFinished?(report) }
        }
    }

    private func finishQueue() {
        let lastIndex = urls.count - 1
        teardown()
        callbackQueue.async { [weak self] in self?.onQueueFinished?(lastIndex) }
    }

    private func interrupt(_ reason: String) {
        controlQueue.async { [weak self] in
            guard let self, self.output != nil else { return }
            self.teardown()
            self.callbackQueue.async { self.onInterrupted?(reason) }
        }
    }

    /// 先停 IO 才收解碼執行緒，獨佔權留給下一段使用
    private func stopSession() {
        monitor?.cancel()
        monitor = nil
        drainedAt = nil
        output?.stop()
        if let current = session {
            current.stopPipelines()
            deliverReports(from: current)
        }
        session = nil
    }

    /// 完整收尾：還原裝置並交還獨佔權
    private func teardown() {
        stopSession()
        output?.release()
        output = nil
    }
}
