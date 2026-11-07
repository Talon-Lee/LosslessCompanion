//
//  PlaybackSessionTests.swift
//  LosslessCompanionTests
//
//  播放中改變佇列時，逐樣本比對輸出。不使用音訊裝置，直接呼叫 render。
//

import Synchronization
import XCTest
@testable import LosslessCompanion

private final class FakeOverloads {
    let total = Atomic<Int>(0)
}

final class PlaybackSessionTests: XCTestCase {
    /// 比緩衝大，解碼端還在這首歌裡就會被擋住
    private static let longFrames = 300_000
    private static let shortFrames = 2_000

    private var files = [URL]()
    private var sessions = [PlaybackSession]()

    override func tearDown() {
        sessions.forEach { $0.stopPipelines() }
        sessions.removeAll()
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files.removeAll()
    }

    private func wav(seed: Int, frames: Int, rate: UInt32 = 44_100) throws -> (url: URL, samples: [Int32]) {
        let samples = (0..<frames * 2).map { Int16(truncatingIfNeeded: seed &* 2_909 &+ $0 &* 7) }
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        append("RIFF"); append(36 + payload); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(rate); append(rate * 4); append(UInt16(4)); append(UInt16(16))
        append("data"); append(payload)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        files.append(url)
        return (url, samples.map { Int32($0) << 16 })
    }

    private func session(_ urls: [URL], overloads: @escaping () -> Int = { 0 }) throws -> PlaybackSession {
        let session = try PlaybackSession(urls: urls, index: 0, startFrame: 0, path: .directInteger, maxBits: 24,
                                          leadInSamples: 0, overloads: overloads)
        sessions.append(session)
        session.startPipelines()
        session.waitForPrefill()
        return session
    }

    /// 送出 count 個樣本，或直到解碼端結束。靜音不算在內，輸出就是實際的音樂資料
    private func render(_ session: PlaybackSession, samples count: Int = .max) -> [Int32] {
        var output = [Int32]()
        var buffer = [Int32](repeating: 0, count: 2_048)
        let deadline = Date().addingTimeInterval(20)
        let core = session.core
        while output.count < count, !core.drained.load(ordering: .acquiring), Date() < deadline {
            let size = min(buffer.count, count - output.count)
            // 這裡比即時播放快得多，不等解碼與驗證端的話會被算成中斷
            let isBehind = core.ring.availableSamples < size && !core.decodeFinished.load(ordering: .acquiring)
            if isBehind || core.tap.freeSpace < size {
                usleep(200)
                continue
            }
            let before = core.renderedSamples.load(ordering: .relaxed)
            buffer.withUnsafeMutableBytes { core.render(into: $0.baseAddress!, byteCount: size * MemoryLayout<Int32>.stride) }
            output += buffer[0..<(core.renderedSamples.load(ordering: .relaxed) - before)]
        }
        return output
    }

    private func reports(_ session: PlaybackSession, expected: Int) -> [PlaybackReport] {
        let deadline = Date().addingTimeInterval(5)
        var collected = [PlaybackReport]()
        while collected.count < expected, Date() < deadline {
            collected += session.takeFinishedReports()
            usleep(5_000)
        }
        return collected
    }

    func testOverloadFromAnEarlierSessionIsNotCountedAgain() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let session = try session([a.url], overloads: { 1 })

        _ = render(session)

        let finished = reports(session, expected: 1)
        XCTAssertEqual(finished.map(\.overloads), [0])
        XCTAssertEqual(finished.map(\.isBitPerfect), [true])
    }

    func testOverloadOnlyFailsTheTrackThatWasPlaying() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let device = FakeOverloads()
        device.total.store(1, ordering: .relaxed)
        let session = try session([a.url, b.url]) { device.total.load(ordering: .relaxed) }

        device.total.add(1, ordering: .relaxed)
        _ = render(session)

        let finished = reports(session, expected: 2)
        XCTAssertEqual(finished.map(\.overloads), [1, 0])
        XCTAssertEqual(finished.map(\.isBitPerfect), [false, true])
    }

    func testTrackInsertedBeforeTheDecoderGetsThereIsGapless() throws {
        let a = try wav(seed: 1, frames: Self.longFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let x = try wav(seed: 3, frames: Self.shortFrames)
        let session = try session([a.url, b.url])

        session.updateQueue([a.url, x.url, b.url])

        XCTAssertTrue(render(session) == a.samples + x.samples + b.samples)
        XCTAssertNil(session.indexAfterDrain)
        let finished = reports(session, expected: 3)
        XCTAssertEqual(finished.map(\.queueIndex), [0, 1, 2])
        for report in finished {
            XCTAssertTrue(report.isBitPerfect, "track \(report.queueIndex): underruns \(report.underruns), drops \(report.tapDrops), "
                          + "samples \(report.decodedSamples)/\(report.outputSamples), md5 \(report.decodedMD5 == report.outputMD5)")
        }
    }

    func testAppendingBeforeTheDecoderFinishesIsGapless() throws {
        let a = try wav(seed: 1, frames: Self.longFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let session = try session([a.url])

        session.updateQueue([a.url, b.url])

        XCTAssertTrue(render(session) == a.samples + b.samples)
        XCTAssertNil(session.indexAfterDrain)
    }

    /// 下一首已經在緩衝裡：現在這首要完整播完，一個樣本都不能多
    func testBufferedTrackIsCutExactlyAtTheEndOfTheCurrentTrack() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let x = try wav(seed: 3, frames: Self.shortFrames)
        let session = try session([a.url, b.url])

        session.updateQueue([a.url, x.url, b.url])

        XCTAssertTrue(render(session) == a.samples)
        XCTAssertEqual(session.indexAfterDrain, 1)
        let finished = reports(session, expected: 1)
        XCTAssertEqual(finished.map(\.queueIndex), [0])
        XCTAssertTrue(finished.allSatisfy(\.isBitPerfect))
    }

    func testCutStopsADecoderBlockedInTheReplacedTrack() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.longFrames)
        let x = try wav(seed: 3, frames: Self.shortFrames)
        let session = try session([a.url, b.url])

        session.updateQueue([a.url, x.url])

        XCTAssertTrue(render(session) == a.samples)
        XCTAssertEqual(session.indexAfterDrain, 1)
    }

    func testRemovingTheRestStopsAtTheCurrentTrack() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let session = try session([a.url, b.url])

        session.updateQueue([a.url])

        XCTAssertTrue(render(session) == a.samples)
        XCTAssertNil(session.indexAfterDrain)
    }

    func testAppendingAfterTheDecoderFinishedPlaysInANewSegment() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let session = try session([a.url])

        session.updateQueue([a.url, b.url])

        XCTAssertTrue(render(session) == a.samples)
        XCTAssertEqual(session.indexAfterDrain, 1)
    }

    func testReplacingATrackWaitingForAClockChange() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames, rate: 96_000)
        let x = try wav(seed: 3, frames: Self.shortFrames)
        let session = try session([a.url, b.url])
        XCTAssertEqual(session.indexAfterDrain, 1)

        session.updateQueue([a.url, x.url, b.url])

        XCTAssertTrue(render(session) == a.samples)
        XCTAssertEqual(session.indexAfterDrain, 1)
    }

    func testSecondChangeAfterACutKeepsTheNewNextTrack() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let x = try wav(seed: 3, frames: Self.shortFrames)
        let y = try wav(seed: 4, frames: Self.shortFrames)
        let session = try session([a.url, b.url])

        session.updateQueue([a.url, x.url, b.url])
        session.updateQueue([a.url, x.url, y.url, b.url])

        XCTAssertTrue(render(session) == a.samples)
        XCTAssertEqual(session.indexAfterDrain, 1)
    }

    /// 按下的瞬間剛好換歌：聲音已經進到下一首，要立刻停下來讓新歌先播
    func testCutPointAlreadyPlayedStopsImmediately() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let x = try wav(seed: 3, frames: Self.shortFrames)
        let session = try session([a.url, b.url])
        let heard = render(session, samples: a.samples.count + 200)

        session.updateQueue([a.url, x.url, b.url])

        XCTAssertEqual(heard.count, a.samples.count + 200)
        XCTAssertTrue(render(session).isEmpty)
        XCTAssertTrue(session.core.drained.load(ordering: .acquiring))
        XCTAssertEqual(session.indexAfterDrain, 1)
    }

    func testUnchangedQueueDoesNotDisturbPlayback() throws {
        let a = try wav(seed: 1, frames: Self.shortFrames)
        let b = try wav(seed: 2, frames: Self.shortFrames)
        let session = try session([a.url, b.url])

        session.updateQueue([a.url, b.url])

        XCTAssertTrue(render(session) == a.samples + b.samples)
        XCTAssertNil(session.indexAfterDrain)
    }
}

final class RenderCoreEndTests: XCTestCase {
    private func core(samples: [Int32]) -> RenderCore {
        let ring = SampleRing(minimumCapacity: 1_024)
        samples.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
        return RenderCore(ring: ring, tap: SampleRing(minimumCapacity: 1_024), path: .directInteger, leadInSamples: 0)
    }

    private func render(_ core: RenderCore, count: Int) -> [Int32] {
        var buffer = [Int32](repeating: -1, count: count)
        buffer.withUnsafeMutableBytes { core.render(into: $0.baseAddress!, byteCount: $0.count) }
        return buffer
    }

    func testOutputStopsAtTheEndSampleEvenWithMoreDataBuffered() {
        let core = core(samples: [1, 2, 3, 4, 5, 6])
        core.endSample.store(4, ordering: .releasing)

        XCTAssertEqual(render(core, count: 6), [1, 2, 3, 4, 0, 0])
        XCTAssertEqual(core.renderedSamples.load(ordering: .relaxed), 4)
        XCTAssertTrue(core.drained.load(ordering: .acquiring))
        XCTAssertEqual(core.underruns.load(ordering: .relaxed), 0)
    }

    func testEndSampleOnABufferBoundaryDrainsOnTheNextCallback() {
        let core = core(samples: [1, 2, 3, 4, 5, 6])
        core.endSample.store(4, ordering: .releasing)

        XCTAssertEqual(render(core, count: 4), [1, 2, 3, 4])
        XCTAssertFalse(core.drained.load(ordering: .acquiring))
        XCTAssertEqual(render(core, count: 2), [0, 0])
        XCTAssertTrue(core.drained.load(ordering: .acquiring))
    }

    func testEndSampleAlreadyPassedDrainsWithoutOutput() {
        let core = core(samples: [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(render(core, count: 4), [1, 2, 3, 4])
        core.endSample.store(2, ordering: .releasing)

        XCTAssertEqual(render(core, count: 2), [0, 0])
        XCTAssertTrue(core.drained.load(ordering: .acquiring))
    }

    func testNoEndSampleStillReportsUnderrun() {
        let core = core(samples: [1, 2])

        XCTAssertEqual(render(core, count: 4), [1, 2, 0, 0])

        XCTAssertFalse(core.drained.load(ordering: .acquiring))
        XCTAssertEqual(core.underruns.load(ordering: .relaxed), 1)
    }
}
