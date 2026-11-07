//
//  StreamSampleAnalyzer.swift
//  LosslessCompanion
//
//  檢查 Music 輸出的樣本有沒有被改動。沒有增益、EQ 或重取樣時，樣本換算回來源位深會落在整數上。
//  實測 Music 內部的浮點運算會多出遠小於 1 LSB 的誤差，音量大的 24-bit 樣本會差到 1 LSB，
//  所以比對都要容許這個誤差。暫停的淡出約 25 ms，判定以秒為單位才不會被它影響。
//

import Foundation

enum StreamReferenceState: Equatable {
    /// 沒有對應的本地檔
    case none
    /// 本地檔的取樣率或位深和串流不同
    case otherVersion
    case searching
    case matching(seconds: Int, exactShare: Double)
    case different
}

enum StreamReplayState: Equatable {
    case firstPlay
    case same
    case different
}

struct StreamSampleReport: Equatable {
    static let minimumSeconds = 3

    var checkedSeconds = 0
    var changedSeconds = 0
    var gaps = 0
    var reference = StreamReferenceState.none
    var replay = StreamReplayState.firstPlay
    /// 取樣比本地檔少了多少開頭；取樣途中重建過時不可靠，是 nil
    var missingHead: TimeInterval?
    /// 上一首換歌時本地檔還沒播到的部分
    var previousMissingTail: TimeInterval?
    /// 冷啟動時開頭是 AAC，之後才換成無損
    var startedLossy = false

    var isUnchanged: Bool { checkedSeconds >= Self.minimumSeconds && changedSeconds == 0 }
    var isChanged: Bool { changedSeconds > 0 }

    var matchesFile: Bool {
        if case .matching(let seconds, _) = reference { return seconds >= Self.minimumSeconds }
        return false
    }
}

/// 解碼後的本地檔，樣本是 32-bit 高位對齊
protocol StreamReferenceSource: AnyObject {
    var frameCount: Int64 { get }
    func read(into destination: UnsafeMutablePointer<Int32>, frames: Int) throws -> Int
    func seek(toFrame frame: Int64) throws
}

extension PCMFileReader: StreamReferenceSource {
    var frameCount: Int64 { format.frameCount }
}

/// 以內容決定切點，兩次播放不必對齊也能比對
struct StreamFingerprint {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private(set) var chunks = [UInt64]()
    private var hash = Self.offsetBasis
    private var isInChunk = false

    mutating func add(left: Int32, right: Int32) {
        let l = UInt32(bitPattern: left), r = UInt32(bitPattern: right)
        if l != 0 || r != 0 {
            var mix = l &* 0x9E37_79B1 &+ r &* 0x85EB_CA6B
            mix ^= mix >> 15
            mix = mix &* 0x2C1B_3C6D
            if mix >> 16 == 0 {
                if isInChunk { chunks.append(hash) }
                isInChunk = true
                hash = Self.offsetBasis
            }
        }
        guard isInChunk else { return }
        hash = (hash ^ UInt64(l)) &* Self.prime
        hash = (hash ^ UInt64(r)) &* Self.prime
    }

    /// 重開一段時，還沒結束的區塊不能算進去
    mutating func restart() {
        isInChunk = false
    }

    static func compare(_ first: [UInt64], _ second: [UInt64]) -> StreamReplayState {
        guard min(first.count, second.count) >= 3 else { return .firstPlay }
        let shared = Set(first).intersection(second).count
        return Double(shared) / Double(min(first.count, second.count)) >= 0.5 ? .same : .different
    }
}

/// 把串流和本地檔逐樣本比對。兩邊的開頭不一定對齊，先用一小段樣本在檔案裡找到位置
final class StreamReferenceComparator {
    private static let patternFrames = 256
    private static let blockFrames = 1 << 16
    /// 取樣剛好跨過跳轉時會找不到，多試幾次才算不同
    private static let searchAttempts = 3
    private static let changedShare = 0.1
    /// 最多回頭看這麼遠，再多就是使用者自己跳過
    private static let tailLimit: TimeInterval = 5

    private let source: StreamReferenceSource
    private let bitDepth: Int
    private let framesPerSecond: Int
    /// 高位對齊後的容許差距：16-bit 四捨五入後要完全相同，24-bit 容許 1 LSB
    private let tolerance: Int64

    private var pattern = [Int32]()
    private var capturedBeforePattern: Int64 = 0
    private var isAligned = false
    private var hasFailed = false
    private var failedSearches = 0
    private var buffer = [Int32]()
    private var windowFrames = 0
    private var windowDifferent = 0
    private var windowExact = 0
    private var matchedSeconds = 0
    private var exactSamples: Int64 = 0
    private var comparedSamples: Int64 = 0
    private var position: Int64 = 0
    private var lastMatched: Int64 = 0
    private var firstAudio: Int64?

    private(set) var missingHead: TimeInterval?

    init(source: StreamReferenceSource, bitDepth: Int, sampleRate: Double) {
        self.source = source
        self.bitDepth = bitDepth
        framesPerSecond = Int(sampleRate)
        tolerance = bitDepth >= 24 ? 1 << (32 - bitDepth) : 0
    }

    var state: StreamReferenceState {
        if hasFailed, matchedSeconds < StreamSampleReport.minimumSeconds { return .different }
        guard matchedSeconds > 0 else { return .searching }
        return .matching(seconds: matchedSeconds, exactShare: Double(exactSamples) / Double(max(comparedSamples, 1)))
    }

    /// 暫停或跳轉後位置變了，要重新尋找
    func restart() {
        isAligned = false
        pattern.removeAll()
        windowFrames = 0
        windowDifferent = 0
        windowExact = 0
    }

    /// samples 是交錯的立體聲，高位對齊
    func feed(_ samples: [Int32], framesBefore: Int64) {
        guard !hasFailed else { return }
        var offset = 0
        if !isAligned {
            if pattern.isEmpty { capturedBeforePattern = framesBefore }
            let needed = Self.patternFrames * 2 - pattern.count
            let taken = min(needed, samples.count)
            pattern.append(contentsOf: samples[0..<taken])
            offset = taken
            guard pattern.count == Self.patternFrames * 2 else { return }
            guard pattern.filter({ $0 != 0 }).count > Self.patternFrames else {
                pattern.removeAll()
                return feed(Array(samples[offset...]), framesBefore: framesBefore + Int64(offset / 2))
            }
            align()
            guard isAligned else { return }
        }
        compare(samples[offset...])
    }

    private func align() {
        do {
            guard let found = try locatePattern() else {
                failedSearches += 1
                hasFailed = failedSearches >= Self.searchAttempts
                pattern.removeAll()
                return
            }
            failedSearches = 0
            if let firstAudio, missingHead == nil {
                let missing = (found - firstAudio) - capturedBeforePattern
                missingHead = max(0, Double(missing) / Double(framesPerSecond))
            }
            position = found + Int64(Self.patternFrames)
            lastMatched = position
            try source.seek(toFrame: position)
            isAligned = true
        }
        catch {
            hasFailed = true
        }
    }

    private func locatePattern() throws -> Int64? {
        try source.seek(toFrame: 0)
        let overlap = Self.patternFrames - 1
        var data = [Int32](repeating: 0, count: (Self.blockFrames + overlap) * 2)
        var carried = 0
        var base: Int64 = 0
        while true {
            let count = try data.withUnsafeMutableBufferPointer {
                try source.read(into: $0.baseAddress! + carried * 2, frames: Self.blockFrames)
            }
            guard count > 0 else { return nil }
            let frames = carried + count
            if firstAudio == nil {
                for index in carried..<frames where data[index * 2] != 0 || data[index * 2 + 1] != 0 {
                    firstAudio = base + Int64(index)
                    break
                }
            }
            if frames >= Self.patternFrames {
                for index in 0...(frames - Self.patternFrames) where matchesPattern(data, at: index) {
                    return base + Int64(index)
                }
            }
            carried = min(overlap, frames)
            data.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: $0.baseAddress! + (frames - carried) * 2, count: carried * 2)
            }
            base += Int64(frames - carried)
        }
    }

    private func matchesPattern(_ data: [Int32], at frame: Int) -> Bool {
        for index in 0..<pattern.count where abs(Int64(data[frame * 2 + index]) - Int64(pattern[index])) > tolerance {
            return false
        }
        return true
    }

    private func compare(_ samples: ArraySlice<Int32>) {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        if buffer.count < frames * 2 { buffer = [Int32](repeating: 0, count: frames * 2) }
        let available: Int
        do {
            available = try buffer.withUnsafeMutableBufferPointer { try source.read(into: $0.baseAddress!, frames: frames) }
        }
        catch {
            hasFailed = true
            return
        }
        var input = samples.startIndex
        for frame in 0..<available {
            var isMatch = true
            for channel in 0..<2 {
                let difference = abs(Int64(samples[input]) - Int64(buffer[frame * 2 + channel]))
                input += 1
                if difference == 0 { windowExact += 1 }
                else if difference > tolerance {
                    windowDifferent += 1
                    isMatch = false
                }
            }
            position += 1
            if isMatch { lastMatched = position }
            windowFrames += 1
            if windowFrames == framesPerSecond {
                commitWindow()
                guard isAligned else { return }
            }
        }
    }

    /// 一整秒對不上多半是跳轉，位置已經不一樣，重新尋找；找不到才算不同
    private func commitWindow() {
        if Double(windowDifferent) > Double(windowFrames * 2) * Self.changedShare {
            restart()
            return
        }
        matchedSeconds += 1
        exactSamples += Int64(windowExact)
        comparedSamples += Int64(windowFrames * 2)
        windowFrames = 0
        windowDifferent = 0
        windowExact = 0
    }

    /// 本地檔最後一個有聲音的位置和最後比對到的位置差多少。歌曲靠近結尾才有意義
    func missingTail() -> TimeInterval? {
        guard lastMatched > 0 else { return nil }
        let limit = Int64(Self.tailLimit * Double(framesPerSecond))
        let remaining = source.frameCount - lastMatched
        guard remaining > 0, remaining <= limit, (try? source.seek(toFrame: lastMatched)) != nil else { return remaining == 0 ? 0 : nil }
        var data = [Int32](repeating: 0, count: Int(remaining) * 2)
        guard let count = try? data.withUnsafeMutableBufferPointer({ try source.read(into: $0.baseAddress!, frames: Int(remaining)) }) else { return nil }
        var last = count
        while last > 0, data[(last - 1) * 2] == 0, data[(last - 1) * 2 + 1] == 0 { last -= 1 }
        return Double(last) / Double(framesPerSecond)
    }
}

final class StreamSampleAnalyzer {
    /// 振幅大的樣本浮點精度不夠，分不出有沒有落在整數上
    private static let gridLimit: Float = 0.25
    private static let gridTolerance: Float = 0.25
    private static let changedShare = 0.1
    private static let minimumTested = 1000
    /// 剛換歌時環形緩衝裡還有上一首的尾巴
    private static let settleTime = 0.25

    private(set) var report = StreamSampleReport()
    private(set) var fingerprint = StreamFingerprint()

    private let scale: Float
    private let shift: Int32
    private let maximum: Float
    private let framesPerSecond: Int
    private let settleFrames: Int
    private let comparator: StreamReferenceComparator?

    private var hasAudio = false
    private var segmentFrames = 0
    private var audioFrames: Int64 = 0
    private var windowFrames = 0
    private var tested = 0
    private var offGrid = 0
    private var integers = [Int32]()
    private var isHeadReliable = true

    init(sampleRate: Double, bitDepth: Int, reference: StreamReferenceState = .none, source: StreamReferenceSource? = nil,
         startedLossy: Bool = false) {
        scale = Float(1 << (bitDepth - 1))
        shift = Int32(32 - bitDepth)
        maximum = Float(1 << (bitDepth - 1)) - 1
        framesPerSecond = Int(sampleRate)
        settleFrames = Int(sampleRate * Self.settleTime)
        comparator = source.map { StreamReferenceComparator(source: $0, bitDepth: bitDepth, sampleRate: sampleRate) }
        report.reference = source == nil ? reference : .searching
        report.startedLossy = startedLossy
    }

    /// samples 是交錯的立體聲
    func feed(_ samples: UnsafeBufferPointer<Float>) {
        integers.removeAll(keepingCapacity: true)
        let framesBefore = audioFrames
        var firstFed: Int64?
        var index = 0
        while index + 1 < samples.count {
            let left = samples[index], right = samples[index + 1]
            index += 2
            if !hasAudio {
                if left == 0 && right == 0 { continue }
                hasAudio = true
            }
            audioFrames += 1
            segmentFrames += 1
            guard segmentFrames > settleFrames else { continue }
            if firstFed == nil { firstFed = audioFrames - 1 }
            grade(left)
            grade(right)
            let l = integer(left), r = integer(right)
            fingerprint.add(left: l >> shift, right: r >> shift)
            integers.append(l)
            integers.append(r)
            windowFrames += 1
            if windowFrames == framesPerSecond { commitWindow() }
        }
        if let comparator, !integers.isEmpty {
            comparator.feed(integers, framesBefore: firstFed ?? framesBefore)
            updateReference()
        }
    }

    /// 暫停或跳轉後是新的一段，前面可能接著淡出
    func beginSegment() {
        hasAudio = false
        segmentFrames = 0
        windowFrames = 0
        tested = 0
        offGrid = 0
        isHeadReliable = false
        fingerprint.restart()
        comparator?.restart()
    }

    /// 開頭的 AAC 已經從頭重播成無損
    func clearLossyStart() {
        report.startedLossy = false
    }

    /// tap 重建時會漏掉一段，開頭比對就不準了
    func markHeadUnreliable() {
        isHeadReliable = false
    }

    func finish() -> TimeInterval? {
        updateReference()
        return comparator?.missingTail()
    }

    private func updateReference() {
        guard let comparator else { return }
        report.reference = comparator.state
        report.missingHead = isHeadReliable ? comparator.missingHead : nil
    }

    private func grade(_ sample: Float) {
        guard sample != 0, abs(sample) < Self.gridLimit else { return }
        tested += 1
        let value = sample * scale
        if abs(value - value.rounded()) > Self.gridTolerance { offGrid += 1 }
    }

    private func integer(_ sample: Float) -> Int32 {
        Int32(max(-maximum - 1, min(maximum, (sample * scale).rounded()))) << shift
    }

    private func commitWindow() {
        if tested >= Self.minimumTested {
            report.checkedSeconds += 1
            if Double(offGrid) > Double(tested) * Self.changedShare { report.changedSeconds += 1 }
        }
        windowFrames = 0
        tested = 0
        offGrid = 0
    }
}
