//
//  StreamSampleTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

private final class MemoryReference: StreamReferenceSource {
    let samples: [Int32]
    private var position = 0

    init(samples: [Int32]) {
        self.samples = samples
    }

    var frameCount: Int64 { Int64(samples.count / 2) }

    func read(into destination: UnsafeMutablePointer<Int32>, frames: Int) throws -> Int {
        let count = min(frames, samples.count / 2 - position)
        guard count > 0 else { return 0 }
        samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress! + position * 2, count: count * 2) }
        position += count
        return count
    }

    func seek(toFrame frame: Int64) throws {
        position = Int(frame)
    }
}

final class StreamSampleTests: XCTestCase {
    private let rate = 44100.0

    /// 固定種子的雜訊，振幅小，全部落在 bits 位元的整數上
    private func noise(seconds: Double, bits: Int, seed: UInt64 = 7) -> [Int32] {
        var state = seed
        let limit = Int32(1) << (bits - 4)
        return (0..<Int(seconds * rate) * 2).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int32(truncatingIfNeeded: state >> 33) % limit
        }
    }

    private func floats(_ samples: [Int32], bits: Int, gain: Float = 1) -> [Float] {
        let scale = Float(1 << (bits - 1))
        return samples.map { Float($0) / scale * gain }
    }

    private func feed(_ analyzer: StreamSampleAnalyzer, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { pointer in
            var offset = 0
            while offset < pointer.count {
                let count = min(16384, pointer.count - offset)
                analyzer.feed(UnsafeBufferPointer(rebasing: pointer[offset..<(offset + count)]))
                offset += count
            }
        }
    }

    func testUntouchedSamplesPass() {
        for bits in [16, 24] {
            let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits)
            feed(analyzer, floats(noise(seconds: 5, bits: bits), bits: bits))
            XCTAssertTrue(analyzer.report.isUnchanged)
            XCTAssertEqual(analyzer.report.checkedSeconds, 4)
        }
    }

    func testFloatRoundingNoiseIsTolerated() {
        // 實測 Music 的樣本會偏離幾個 ULP
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: 24)
        let samples = floats(noise(seconds: 5, bits: 24), bits: 24).enumerated().map { index, value in
            index % 3 == 0 ? value.nextUp.nextUp : value
        }
        feed(analyzer, samples)
        XCTAssertTrue(analyzer.report.isUnchanged)
    }

    func testVolumeChangeIsDetected() {
        for bits in [16, 24] {
            let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits)
            feed(analyzer, floats(noise(seconds: 5, bits: bits), bits: bits, gain: 0.8))
            XCTAssertTrue(analyzer.report.isChanged)
            XCTAssertFalse(analyzer.report.isUnchanged)
        }
    }

    func testPauseFadeDoesNotCountAsChange() {
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: 16)
        var samples = floats(noise(seconds: 5, bits: 16), bits: 16)
        let fadeStart = samples.count - Int(rate * 0.025) * 2 - Int(rate) * 2
        for index in fadeStart..<(fadeStart + Int(rate * 0.025) * 2) {
            samples[index] *= 0.5
        }
        feed(analyzer, samples)
        XCTAssertTrue(analyzer.report.isUnchanged)
    }

    func testSilenceIsNotChecked() {
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: 16)
        feed(analyzer, [Float](repeating: 0, count: Int(rate) * 10))
        XCTAssertEqual(analyzer.report.checkedSeconds, 0)
        XCTAssertFalse(analyzer.report.isUnchanged)
    }

    private func highAligned(_ samples: [Int32], bits: Int) -> [Int32] {
        samples.map { $0 << (32 - bits) }
    }

    func testMatchesLocalFile() {
        let bits = 24
        let samples = noise(seconds: 6, bits: bits)
        let source = MemoryReference(samples: highAligned(samples, bits: bits))
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits, source: source)
        feed(analyzer, floats(samples, bits: bits))
        let tail = analyzer.finish()
        XCTAssertTrue(analyzer.report.matchesFile)
        guard case .matching(_, let share) = analyzer.report.reference else { return XCTFail() }
        XCTAssertEqual(share, 1, accuracy: 0.0001)
        XCTAssertEqual(analyzer.report.missingHead, 0)
        XCTAssertEqual(tail, 0)
    }

    func testFindsPositionWhenCaptureStartsLate() {
        let bits = 16
        let samples = noise(seconds: 8, bits: bits)
        let source = MemoryReference(samples: highAligned(samples, bits: bits))
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits, source: source)
        feed(analyzer, floats(Array(samples.dropFirst(Int(rate) * 2)), bits: bits))
        _ = analyzer.finish()
        XCTAssertTrue(analyzer.report.matchesFile)
        XCTAssertEqual(analyzer.report.missingHead ?? 0, 1, accuracy: 0.001)
    }

    func testReportsMissingTail() {
        let bits = 16
        let samples = noise(seconds: 6, bits: bits)
        let source = MemoryReference(samples: highAligned(samples, bits: bits))
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits, source: source)
        feed(analyzer, floats(Array(samples.dropLast(Int(rate * 0.3) * 2)), bits: bits))
        XCTAssertEqual(analyzer.finish() ?? 0, 0.3, accuracy: 0.001)
    }

    func testFindsPositionAgainAfterSeek() {
        let bits = 16
        let samples = noise(seconds: 20, bits: bits)
        let source = MemoryReference(samples: highAligned(samples, bits: bits))
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits, source: source)
        let seconds = Int(rate) * 2
        // 跳轉的通知比聲音早：還沒收到新一段，串流就換了位置
        feed(analyzer, floats(Array(samples[0..<(seconds * 5)]), bits: bits))
        feed(analyzer, floats(Array(samples[(seconds * 12)...]), bits: bits))
        XCTAssertTrue(analyzer.report.matchesFile)
        guard case .matching(let matched, _) = analyzer.report.reference else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(matched, 9)
    }

    func testDifferentMasterIsReported() {
        let bits = 16
        let source = MemoryReference(samples: highAligned(noise(seconds: 6, bits: bits, seed: 1), bits: bits))
        let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: bits, source: source)
        feed(analyzer, floats(noise(seconds: 6, bits: bits, seed: 2), bits: bits))
        XCTAssertEqual(analyzer.report.reference, .different)
    }

    func testFingerprintSurvivesDifferentStart() {
        func chunks(from start: Int) -> [UInt64] {
            let analyzer = StreamSampleAnalyzer(sampleRate: rate, bitDepth: 16)
            feed(analyzer, floats(Array(samples.dropFirst(start)), bits: 16))
            return analyzer.fingerprint.chunks
        }
        let samples = noise(seconds: 30, bits: 16)
        XCTAssertEqual(StreamFingerprint.compare(chunks(from: 0), chunks(from: 88200)), .same)

        let other = StreamSampleAnalyzer(sampleRate: rate, bitDepth: 16)
        feed(other, floats(noise(seconds: 30, bits: 16, seed: 9), bits: 16))
        XCTAssertEqual(StreamFingerprint.compare(chunks(from: 0), other.fingerprint.chunks), .different)
    }

    func testParsesDecoderLines() {
        let alac = StreamFormat(logLine: "ACAppleLosslessDecoder.cpp:680 (0x1) Input format:  2 ch,  96000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet")
        XCTAssertEqual(alac, StreamFormat(sampleRate: 96000, bitDepth: 24))
        let aac = StreamFormat(logLine: "ACMP4AACBaseDecoder.cpp:310 (0x1) Input format:  2 ch,  44100 Hz, aac  (0x00000000) 0 bits/channel, 0 bytes/packet")
        XCTAssertEqual(aac?.lossyCodec, "AAC")
        XCTAssertEqual(aac?.isLossless, false)
        XCTAssertNil(StreamFormat(logLine: "ACCPEDecoderWrapper.cpp:319 (0x1) Input format:  2 ch,  44100 Hz, qlac (0x00000001) 0 bits/channel"))
    }

    func testLosslessReplacesLossyStart() {
        var tracker = MusicFormatTracker()
        let start = Date()
        _ = tracker.playerStartedPlaying(trackID: "A", at: start)
        let lossy = StreamFormat(sampleRate: 44100, bitDepth: 0, lossyCodec: "AAC")
        let lossless = StreamFormat(sampleRate: 44100, bitDepth: 16)
        XCTAssertEqual(tracker.formatSeen(lossy, at: start.addingTimeInterval(0.5)), lossy)
        XCTAssertEqual(tracker.formatSeen(lossless, at: start.addingTimeInterval(1)), lossless)
        XCTAssertEqual(tracker.currentFormat, lossless)
        // 無損確定之後，再出現的是預載的下一首
        XCTAssertNil(tracker.formatSeen(lossy, at: start.addingTimeInterval(2)))
        XCTAssertEqual(tracker.currentFormat, lossless)
    }

    func testPreviousTrackFormatIsNotReused() {
        var tracker = MusicFormatTracker()
        let start = Date()
        let first = StreamFormat(sampleRate: 44100, bitDepth: 16)
        _ = tracker.playerStartedPlaying(trackID: "A", at: start)
        _ = tracker.formatSeen(first, at: start.addingTimeInterval(1))
        XCTAssertEqual(tracker.currentTrackFormat, first)

        tracker.playerStopped(at: start.addingTimeInterval(9))
        _ = tracker.playerStartedPlaying(trackID: "B", at: start.addingTimeInterval(10))
        // DAC 規格要留到新規格出現，但這不是 B 的規格
        XCTAssertEqual(tracker.currentFormat, first)
        XCTAssertNil(tracker.currentTrackFormat)

        let second = StreamFormat(sampleRate: 96000, bitDepth: 24)
        _ = tracker.formatSeen(second, at: start.addingTimeInterval(11))
        XCTAssertEqual(tracker.currentTrackFormat, second)
    }

    func testParsesSignals() {
        XCTAssertEqual(MusicLogSignal(logLine: "AudioFormatCommon.cpp:328   inSoundCheckEnabled 0"), .soundCheck(false))
        XCTAssertEqual(MusicLogSignal(logLine: "AudioFormatCommon.cpp:328   inSoundCheckEnabled 1"), .soundCheck(true))
        XCTAssertEqual(MusicLogSignal(logLine: "SoundEnhancerEffectsProcessor::SetSESettings 127 / 0.50 (disabled)"), .soundEnhancer(false))
        XCTAssertEqual(MusicLogSignal(logLine: "SoundEnhancerEffectsProcessor::SetSESettings 127 / 0.50 (enabled)"), .soundEnhancer(true))
        XCTAssertEqual(MusicLogSignal(logLine: "HALC_ProxyIOContext: skipping cycle due to overload"), .overload)
        XCTAssertNil(MusicLogSignal(logLine: "something else"))
    }

    private func cleanPath() -> StreamPathStatus {
        var path = StreamPathStatus()
        path.format = StreamFormat(sampleRate: 96000, bitDepth: 24)
        path.device = StreamDeviceState(sampleRate: 96000, bitDepth: 24, isInteger: true, isPhysical: true, transport: "USB", volume: 1)
        path.music = MusicProcessing()
        path.soundCheck = false
        path.transitions = false
        path.soundEnhancer = false
        return path
    }

    func testVerdictLevels() {
        let path = cleanPath()
        XCTAssertEqual(path.verdict(deviceName: "DAC", sampling: .off), .cleanPath)

        // 樣本結果不再顯示，標題只看路徑本身
        var report = StreamSampleReport()
        report.checkedSeconds = 10
        report.changedSeconds = 1
        XCTAssertEqual(path.verdict(deviceName: "DAC", sampling: .running(report)), .cleanPath)
    }

    func testEachProblemIsWarned() {
        func processed(_ change: (inout StreamPathStatus) -> Void) -> Bool {
            var path = cleanPath()
            change(&path)
            return path.verdict(deviceName: "DAC", sampling: .off) == .processed
        }
        XCTAssertTrue(processed { $0.format = StreamFormat(sampleRate: 44100, bitDepth: 0, lossyCodec: "AAC") })
        XCTAssertTrue(processed { $0.device?.sampleRate = 44100 })
        XCTAssertTrue(processed { $0.device?.bitDepth = 16 })
        XCTAssertTrue(processed { $0.device?.volume = 0.5 })
        XCTAssertTrue(processed { $0.device?.isMuted = true })
        XCTAssertTrue(processed { $0.device?.isPhysical = false })
        XCTAssertTrue(processed { $0.music?.volume = 80 })
        XCTAssertTrue(processed { $0.music?.isEQEnabled = true })
        XCTAssertTrue(processed { $0.music?.trackEQ = "Rock" })
        XCTAssertTrue(processed { $0.music?.trackAdjustment = 10 })
        XCTAssertTrue(processed { $0.music?.isAirPlay = true })
        XCTAssertTrue(processed { $0.soundCheck = true })
        XCTAssertTrue(processed { $0.transitions = true })
        XCTAssertTrue(processed { $0.soundEnhancer = true })
        XCTAssertTrue(processed { $0.overloads = 1 })
    }

    func testReplaysOnlyWhenTheSameTrackStartedLossy() {
        let aac = StreamFormat(sampleRate: 44100, bitDepth: 0, lossyCodec: "AAC")
        let alac = StreamFormat(sampleRate: 44100, bitDepth: 24)
        var tracker = LossyStartTracker()
        XCTAssertFalse(tracker.formatSeen(alac, trackID: "A"))
        XCTAssertFalse(tracker.formatSeen(aac, trackID: "B"))
        XCTAssertTrue(tracker.formatSeen(alac, trackID: "B"))
        // 只重播一次
        XCTAssertFalse(tracker.formatSeen(alac, trackID: "B"))

        // 有損的是上一首時不算
        _ = tracker.formatSeen(aac, trackID: "C")
        tracker.trackChanged()
        XCTAssertFalse(tracker.formatSeen(alac, trackID: "D"))
    }

    func testWarningNeedsTwoChecks() {
        var filter = StreamWarningFilter()
        filter.update("DAC 格式：44.1 kHz，與歌曲不同")
        XCTAssertNil(filter.warning)
        filter.update("DAC 格式：44.1 kHz，與歌曲不同")
        XCTAssertEqual(filter.warning, "DAC 格式：44.1 kHz，與歌曲不同")
        filter.update(nil)
        XCTAssertNil(filter.warning)
        filter.update("混音：Safari")
        XCTAssertNil(filter.warning)
    }

    func testFirstProblemNamesTheRow() {
        var path = cleanPath()
        XCTAssertNil(path.firstProblem(deviceName: "DAC", sampling: .off))
        path.device?.isMuted = true
        XCTAssertNotNil(path.firstProblem(deviceName: "DAC", sampling: .off))
    }

    func testUnknownSettingNeverClaimsClean() {
        var path = cleanPath()
        path.soundEnhancer = nil
        XCTAssertEqual(path.verdict(deviceName: "DAC", sampling: .off), .unknown)
    }
}
