//
//  EnginePortTests.swift
//  LosslessCompanionTests
//
//  確認移植過來的引擎在這個 App 裡正常運作。不使用任何真實音訊裝置。
//

import CoreAudio
import CryptoKit
import XCTest
@testable import LosslessCompanion

final class EnginePortTests: XCTestCase {
    private var fileURL: URL!

    private let samples: [Int16] = (0..<4_000).map { Int16(truncatingIfNeeded: $0 &* 257 &- 12_345) }

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try makeWAV(samples: samples).write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeWAV(samples: [Int16], rate: UInt32 = 44_100) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        append("RIFF"); append(36 + payload); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(rate); append(rate * 4); append(UInt16(4)); append(UInt16(16))
        append("data"); append(payload)
        samples.forEach { append($0) }
        return data
    }

    func testDecoderKeepsSamplesHighAlignedAndUnchanged() throws {
        let reader = try PCMFileReader(url: fileURL)
        XCTAssertEqual(reader.format.sampleRate, 44_100)
        XCTAssertEqual(reader.format.bitsPerSample, 16)

        let frames = samples.count / 2
        let buffer = UnsafeMutablePointer<Int32>.allocate(capacity: samples.count)
        defer { buffer.deallocate() }
        var total = 0
        while total < frames {
            let count = try reader.read(into: buffer + total * 2, frames: frames - total)
            if count == 0 { break }
            total += count
        }

        XCTAssertEqual(total, frames)
        for index in samples.indices {
            XCTAssertEqual(buffer[index], Int32(samples[index]) << 16, "sample \(index)")
        }
    }

    func testInspectorAcceptsPCMFile() throws {
        let track = try LibraryInspector.inspect(url: fileURL)

        XCTAssertEqual(track.frameCount, Int64(samples.count / 2))
        XCTAssertEqual(track.bitsPerSample, 16)
    }

    /// 走完整的輔助程序路徑：App 重新啟動自己的執行檔、用 JSON 溝通、失敗時回報並退出
    func testHelperProcessStartsFromThisBundleAndReportsMissingDevice() {
        let client = BitPerfectClient()

        XCTAssertThrowsError(try client.play(urls: [fileURL], deviceUID: "LosslessCompanion.NoSuchDevice")) { error in
            XCTAssertEqual(error.localizedDescription, BitPerfectError.deviceNotFound.errorDescription)
        }

        let released = expectation(description: "helper exits")
        DispatchQueue.global().async {
            for _ in 0..<300 where BitPerfectClient.isExclusive { usleep(10_000) }
            released.fulfill()
        }
        wait(for: [released], timeout: 5)
        XCTAssertFalse(BitPerfectClient.isExclusive)
    }

    /// FLAC 的 MD5 定義是小端序的原始 PCM，算出來要和直接雜湊檔案內容相同
    func testHasherMatchesRawPCMBytes() {
        var hasher = PCMHasher(bitsPerSample: 16)
        let aligned = samples.map { Int32($0) << 16 }
        aligned.withUnsafeBufferPointer { hasher.update($0) }

        var bytes = Data()
        samples.forEach { sample in withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) } }

        XCTAssertEqual(hasher.finalized(), Data(Insecure.MD5.hash(data: bytes)))
    }
}

final class DirectFormatTests: XCTestCase {
    private func format(flags: AudioFormatFlags, bits: UInt32, bytes: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: bytes,
                                    mFramesPerPacket: 1, mBytesPerFrame: bytes, mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
    }

    func testTwentyFourBitsAlignedHighInThirtyTwoBitContainer() {
        XCTAssertTrue(ExclusiveOutput.isDirectInteger(format(flags: 0x54, bits: 24, bytes: 8)))
    }

    func testPackedThirtyTwoBitsFillTheContainer() {
        XCTAssertTrue(ExclusiveOutput.isDirectInteger(format(flags: 0x4C, bits: 32, bytes: 8)))
    }

    func testPackedTwentyFourBitsInThirtyTwoBitContainerWouldBeShifted() {
        XCTAssertFalse(ExclusiveOutput.isDirectInteger(format(flags: 0x4C, bits: 24, bytes: 8)))
    }

    func testThreeByteAndTwoByteSamplesAreNotDirect() {
        XCTAssertFalse(ExclusiveOutput.isDirectInteger(format(flags: 0x4C, bits: 24, bytes: 6)))
        XCTAssertFalse(ExclusiveOutput.isDirectInteger(format(flags: 0x4C, bits: 16, bytes: 4)))
    }

    func testMixableAndFloatFormatsAreNotDirect() {
        XCTAssertFalse(ExclusiveOutput.isDirectInteger(format(flags: 0x0C, bits: 32, bytes: 8)))
        XCTAssertFalse(ExclusiveOutput.isDirectInteger(format(flags: 0x09, bits: 32, bytes: 8)))
    }
}

final class OutputMemoryTests: XCTestCase {
    func testDefaultMovedAwayDuringExclusiveIsIgnored() {
        var memory = OutputMemory(defaultUID: "DAC")

        XCTAssertFalse(memory.defaultChanged(to: "Speakers", isExclusive: true))

        XCTAssertEqual(memory.defaultUID, "DAC")
    }

    func testRealDeviceChangeIsRemembered() {
        var memory = OutputMemory(defaultUID: "DAC")

        XCTAssertTrue(memory.defaultChanged(to: "Headphones", isExclusive: false))

        XCTAssertEqual(memory.defaultUID, "Headphones")
    }

    func testRepeatedNotificationIsNotAChange() {
        var memory = OutputMemory(defaultUID: "DAC")

        XCTAssertFalse(memory.defaultChanged(to: "DAC", isExclusive: false))
    }

    func testSelectedDeviceWinsWhileConnected() {
        let memory = OutputMemory(defaultUID: "DAC")

        XCTAssertEqual(memory.resolve(selected: "Other") { _ in true }, "Other")
        XCTAssertEqual(memory.resolve(selected: "Other") { _ in false }, "DAC")
    }
}
