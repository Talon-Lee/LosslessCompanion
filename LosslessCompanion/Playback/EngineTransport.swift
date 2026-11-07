//
//  EngineTransport.swift
//  LosslessCompanion
//
//  BitPerfectClient 的方法會阻塞到輔助程序回應，這裡把它們移到背景佇列。
//

import Foundation

final class EngineTransport: LocalTransport {
    var onTrackStarted: ((Int, AudioSourceFormat, OutputPath) -> Void)?
    var onPosition: ((Int, Int64) -> Void)?
    var onVerified: ((Int, TrackResult) -> Void)?
    var onFinished: ((Int) -> Void)?
    var onInterrupted: ((String) -> Void)?

    private let client = BitPerfectClient()
    private let queue = DispatchQueue(label: "EngineTransport", qos: .userInitiated)
    private let options: (String) -> OutputOptions
    /// 輔助程序獨佔 DAC 之前在背景佇列執行，Hog 模式用來先交還橋接
    var beforeExclusive: (() -> Void)?

    /// options：依裝置 UID 取得目前的設定，每次開始播放時讀取
    init(options: @escaping (String) -> OutputOptions = { _ in OutputOptions() }) {
        self.options = options
        client.onTrackStarted = { [weak self] index, format, path in self?.onTrackStarted?(index, format, path) }
        client.onPosition = { [weak self] index, frame in self?.onPosition?(index, frame) }
        client.onTrackFinished = { [weak self] result in self?.onVerified?(result.queueIndex, result) }
        client.onQueueFinished = { [weak self] in self?.onFinished?($0) }
        client.onInterrupted = { [weak self] reason in self?.onInterrupted?(reason) }
    }

    func play(tracks: [LibraryTrack], deviceUID: String, completion: @escaping (Error?) -> Void) {
        let urls = tracks.map(\.url)
        let outputOptions = options(deviceUID)
        let beforeExclusive = beforeExclusive
        queue.async { [client] in
            var failure: Error?
            beforeExclusive?()
            do {
                try client.play(urls: urls, deviceUID: deviceUID, options: outputOptions)
            }
            catch {
                failure = error
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    func setPaused(_ paused: Bool) {
        // 暫停太久而交還 DAC 時，繼續播放會重新獨佔
        let beforeExclusive = paused ? nil : beforeExclusive
        perform { beforeExclusive?(); try $0.setPaused(paused) }
    }

    func seek(toFrame frame: Int64) {
        perform { try $0.seek(toFrame: frame) }
    }

    func skip(toIndex index: Int) {
        let beforeExclusive = beforeExclusive
        perform { beforeExclusive?(); try $0.skip(toIndex: index) }
    }

    func replaceUpcoming(after index: Int, with tracks: [LibraryTrack]) {
        let urls = tracks.map(\.url)
        queue.async { [client] in client.replaceUpcoming(after: index, with: urls) }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async { [client] in
            client.stop()
            DispatchQueue.main.async(execute: completion)
        }
    }

    func stopAndWait() {
        queue.sync { client.stop() }
    }

    private func perform(_ action: @escaping (BitPerfectClient) throws -> Void) {
        queue.async { [weak self, client] in
            do {
                try action(client)
            }
            catch {
                DispatchQueue.main.async { self?.onInterrupted?(error.localizedDescription) }
            }
        }
    }
}
