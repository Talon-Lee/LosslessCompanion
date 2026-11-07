//
//  StreamBridgeTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

final class StreamBridgeTests: XCTestCase {
    /// 模擬 DAC 跑得比名目慢，Bridge 依控制器給的速度前進：相位要鎖住，不能累積
    private func simulate(dacPPM: (Double) -> Double, seconds: Double, rate: Double = 44100) -> (maxError: Double, finalError: Double) {
        var clock = BridgeClock(rate: rate)
        var bridgeSample = 0.0, dacSample = 1000.0, scale = 1.0
        var maxError = 0.0, finalError = 0.0
        let step = 0.5
        var t = 0.0
        while t < seconds {
            let update = clock.update(seconds: t, bridgeSample: bridgeSample, dacSample: dacSample)
            scale = update.scale
            if t > 5 { maxError = max(maxError, abs(update.error)) }
            finalError = update.error
            // 驅動在下一個週期才套用新的速度，這裡也晚一步
            bridgeSample += rate * scale * step
            dacSample += rate * (1 + dacPPM(t) / 1e6) * step
            t += step
        }
        return (maxError, finalError)
    }

    func testLocksToAConstantlySlowDAC() {
        let result = simulate(dacPPM: { _ in -13.8 }, seconds: 600)
        XCTAssertLessThan(result.maxError, 2)
        XCTAssertLessThan(abs(result.finalError), 0.5)
    }

    /// 實測時 DAC 在四分鐘內從 +13 擺到 +36 再到 -4 ppm
    func testFollowsAWanderingDAC() {
        let result = simulate(dacPPM: { t in t < 90 ? 13 + t / 4 : max(-4, 36 - (t - 90) / 3) }, seconds: 300)
        XCTAssertLessThan(result.maxError, 20, "相位誤差要遠小於 4096 樣本的緩衝")
    }

    func testGridFollowsTheSourceBitDepth() {
        XCTAssertEqual(StreamRateMatcher.gridBits(StreamFormat(sampleRate: 44100, bitDepth: 16)), 16)
        XCTAssertEqual(StreamRateMatcher.gridBits(StreamFormat(sampleRate: 96000, bitDepth: 24)), 24)
        XCTAssertEqual(StreamRateMatcher.gridBits(StreamFormat(sampleRate: 44100, bitDepth: 0, lossyCodec: "AAC")), 24)
        XCTAssertEqual(StreamRateMatcher.gridBits(nil), 24)
    }

    /// Music 的輸出比原始值多或少幾個 Float32 最小單位，四捨五入到 16-bit 格點就回到原值
    func testRoundingToTheSourceGridRestoresMusicOutput() {
        let originals: [Int16] = [-1531, 9812, -11292, 32767, -32768, 0, 1]
        for value in originals {
            let exact = Float(value) / 32768
            for ulps in -4...4 {
                var sample = exact
                for _ in 0..<abs(ulps) { sample = ulps > 0 ? sample.nextUp : sample.nextDown }
                let rounded = min(max((Double(sample) * 32768).rounded(), -32768), 32767)
                XCTAssertEqual(Int32(rounded) << 16, Int32(value) << 16, "\(value) off by \(ulps) ulps")
            }
        }
    }
}
