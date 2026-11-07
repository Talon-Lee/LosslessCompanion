//
//  BitPerfectHelper.swift
//  LosslessCompanion
//
//  獨佔輸出在獨立的輔助程序裡執行，每段播放一個程序，結束就退出。
//  同一程序重複獨佔時，AudioDeviceStart 會逾時失敗（錯誤 35）；用 AudioHardwareUnload 重置
//  雖然能解決，卻會讓 Apple Music 對這台 DAC 的輸出卡死到重開為止。程序結束則完全沒有這個問題。
//  App 被強制結束時，輔助程序讀到 stdin 結束，也會自己還原 DAC。
//

import Foundation
import Synchronization

// MARK: - Protocol

private struct HelperCommand: Codable {
    enum Kind: String, Codable {
        case play, pause, seek, skip, upcoming, stop
    }

    let kind: Kind
    var paths: [String]?
    var index: Int?
    var frame: Int64?
    var deviceUID: String?
    var paused: Bool?
    var options: OutputOptions?
}

private struct HelperEvent: Codable {
    enum Kind: String, Codable {
        case started, failed, track, position, trackFinished, queueFinished, interrupted, suspended
    }

    let kind: Kind
    var index: Int?
    var frame: Int64?
    var message: String?
    var sampleRate: Double?
    var bitsPerSample: Int?
    var frameCount: Int64?
    var outputPath: String?
    var passed: Bool?
    var matchedFile: Bool?
}

/// 一首歌播完後的驗證結果
struct TrackResult {
    let queueIndex: Int
    let passed: Bool
    /// 也和 FLAC 檔案內建的 MD5 相符
    let matchedFile: Bool
}

// MARK: - Helper process

enum BitPerfectHelper {
    static let launchFlag = "--bitperfect-helper"

    private static let outputLock = NSLock()

    /// 以 launchFlag 啟動時取代 App 主程式
    static func run() -> Never {
        let engine = BitPerfectEngine()
        let commands = DispatchQueue(label: "BitPerfect.helper")

        engine.onTrackStarted = { index, format, path in
            send(HelperEvent(kind: .track, index: index, sampleRate: format.sampleRate,
                             bitsPerSample: format.bitsPerSample, frameCount: format.frameCount,
                             outputPath: path.rawValue))
        }
        engine.onPosition = { index, frame in
            send(HelperEvent(kind: .position, index: index, frame: frame))
        }
        engine.onTrackFinished = { report in
            send(HelperEvent(kind: .trackFinished, index: report.queueIndex, passed: report.isBitPerfect,
                             matchedFile: report.decoderMatchesFile == true))
        }
        engine.onQueueFinished = { lastIndex in
            send(HelperEvent(kind: .queueFinished, index: lastIndex))
            exit(0)
        }
        engine.onInterrupted = { reason in
            send(HelperEvent(kind: .interrupted, message: reason))
            exit(0)
        }
        engine.onSuspended = { index, frame in
            send(HelperEvent(kind: .suspended, index: index, frame: frame))
            exit(0)
        }

        // App 被強制結束時，回報事件會寫進斷掉的管道。預設行為是直接被系統殺掉，
        // 那樣就等不到下面的 stdin 結束，DAC 會留在獨佔格式
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: commands)
        termination.setEventHandler {
            engine.stop()
            exit(0)
        }
        termination.resume()

        let reader = Thread {
            while let line = readLine(), let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(HelperCommand.self, from: data) {
                commands.async { perform(command, on: engine) }
            }
            // 讀不到指令代表 App 已經結束，不能把 DAC 留在獨佔狀態
            commands.async {
                engine.stop()
                exit(0)
            }
        }
        reader.start()
        dispatchMain()
    }

    private static func perform(_ command: HelperCommand, on engine: BitPerfectEngine) {
        do {
            switch command.kind {
            case .play:
                try engine.play(urls: (command.paths ?? []).map { URL(fileURLWithPath: $0) },
                                startIndex: command.index ?? 0,
                                startFrame: command.frame ?? 0,
                                deviceUID: command.deviceUID ?? "",
                                options: command.options ?? OutputOptions())
                send(HelperEvent(kind: .started))
            case .pause:
                engine.setPaused(command.paused ?? false)
            case .seek:
                try engine.seek(toFrame: command.frame ?? 0)
            case .skip:
                try engine.skip(toIndex: command.index ?? 0)
            case .upcoming:
                engine.replaceUpcoming(after: command.index ?? 0, with: (command.paths ?? []).map { URL(fileURLWithPath: $0) })
            case .stop:
                engine.stop()
                exit(0)
            }
        }
        catch {
            send(HelperEvent(kind: .failed, message: error.localizedDescription))
            engine.stop()
            exit(0)
        }
    }

    private static func send(_ event: HelperEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(UInt8(ascii: "\n"))
        outputLock.lock()
        try? FileHandle.standardOutput.write(contentsOf: data)
        outputLock.unlock()
    }
}

// MARK: - App side

private struct HelperError: LocalizedError {
    let errorDescription: String?
}

/// App 這一端的播放介面。方法會阻塞到輔助程序回應，請勿在主執行緒呼叫 play 與 stop。
/// 回呼一律在主執行緒執行
final class BitPerfectClient {
    private static let exclusiveFlag = Atomic<Bool>(false)

    /// 輔助程序持有 DAC 期間為 true；取樣率自動切換邏輯據此暫停，避免和它互相干擾
    static var isExclusive: Bool {
        exclusiveFlag.load(ordering: .sequentiallyConsistent)
    }

    var onTrackStarted: ((Int, AudioSourceFormat, OutputPath) -> Void)?
    var onTrackFinished: ((TrackResult) -> Void)?
    var onPosition: ((Int, Int64) -> Void)?
    /// 參數是輔助程序實際播到的最後一首：剛結束時才加入的歌，它沒有收到
    var onQueueFinished: ((Int) -> Void)?
    var onInterrupted: ((String) -> Void)?

    private static let startTimeout: TimeInterval = 15
    private static let stopTimeout: TimeInterval = 3
    private static let endingPolls = 200

    /// 保護下列狀態；等待輔助程序時不持有
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pendingLine = Data()
    private var startSignal: DispatchSemaphore?
    private var startError: String?
    private var exitSignal: DispatchSemaphore?
    private var endedCleanly = false
    private var endCallback: (() -> Void)?
    private var urls = [URL]()
    private var deviceUID = ""
    private var options = OutputOptions()
    private var isPaused = false
    private var suspended: (index: Int, frame: Int64)?

    func play(urls: [URL], startIndex: Int = 0, startFrame: Int64 = 0, deviceUID: String, options: OutputOptions = OutputOptions()) throws {
        // 換裝置要交還原本那台，所以要換一個輔助程序
        if isRunning(on: deviceUID) == false { stop() }
        lock.lock()
        self.urls = urls
        self.deviceUID = deviceUID
        self.options = options
        isPaused = false
        suspended = nil
        lock.unlock()
        try sendPlay(index: startIndex, frame: startFrame)
    }

    func setPaused(_ paused: Bool) throws {
        lock.lock()
        isPaused = paused
        let resumeAt = suspended
        if !paused { suspended = nil }
        lock.unlock()

        if !paused, let resumeAt {
            try sendPlay(index: resumeAt.index, frame: resumeAt.frame)
        }
        else {
            send(HelperCommand(kind: .pause, paused: paused))
        }
    }

    func seek(toFrame frame: Int64) throws {
        lock.lock()
        let wasSuspended = suspended != nil
        if let current = suspended { suspended = (current.index, frame) }
        lock.unlock()
        if !wasSuspended { send(HelperCommand(kind: .seek, frame: frame)) }
    }

    func skip(toIndex index: Int) throws {
        lock.lock()
        let wasSuspended = suspended != nil
        suspended = nil
        lock.unlock()
        if wasSuspended {
            try sendPlay(index: index, frame: 0)
        }
        else {
            send(HelperCommand(kind: .skip, index: index))
        }
    }

    /// 暫停太久而交還 DAC 時，輔助程序已經不在，繼續播放時用這裡記下的清單
    func replaceUpcoming(after index: Int, with upcoming: [URL]) {
        lock.lock()
        if urls.indices.contains(index) { urls = Array(urls[...index]) + upcoming }
        lock.unlock()
        send(HelperCommand(kind: .upcoming, paths: upcoming.map(\.path), index: index))
    }

    /// 同步完成，返回時 DAC 已還原並釋放
    func stop() {
        lock.lock()
        suspended = nil
        guard let process else {
            lock.unlock()
            return
        }
        endedCleanly = true
        let exited = DispatchSemaphore(value: 0)
        exitSignal = exited
        lock.unlock()

        send(HelperCommand(kind: .stop))
        if exited.wait(timeout: .now() + Self.stopTimeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + Self.stopTimeout)
        }
    }

    /// 沒有輔助程序時回傳 nil
    private func isRunning(on uid: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return process == nil ? nil : deviceUID == uid
    }

    /// 上一段播放剛結束時，輔助程序可能還沒退出，指令送過去也不會有回應
    private func waitForEndingHelper() {
        for _ in 0..<Self.endingPolls {
            lock.lock()
            let ending = process != nil && endedCleanly
            lock.unlock()
            if !ending { return }
            usleep(10_000)
        }
    }

    private func sendPlay(index: Int, frame: Int64) throws {
        waitForEndingHelper()
        let ready = DispatchSemaphore(value: 0)
        lock.lock()
        startSignal = ready
        startError = nil
        let paths = urls.map(\.path)
        let uid = deviceUID
        let outputOptions = options
        let paused = isPaused
        lock.unlock()

        try launchIfNeeded()
        send(HelperCommand(kind: .play, paths: paths, index: index, frame: frame, deviceUID: uid, options: outputOptions))

        guard ready.wait(timeout: .now() + Self.startTimeout) == .success else {
            stop()
            throw HelperError(errorDescription: String(localized: "輔助程序沒有回應"))
        }
        lock.lock()
        let failure = startError
        lock.unlock()
        if let failure { throw HelperError(errorDescription: failure) }
        if paused { send(HelperCommand(kind: .pause, paused: true)) }
    }

    private func launchIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }

        guard let executable = Bundle.main.executableURL else {
            throw HelperError(errorDescription: String(localized: "找不到輔助程序"))
        }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [BitPerfectHelper.launchFlag]
        let commandPipe = Pipe()
        let eventPipe = Pipe()
        helper.standardInput = commandPipe
        helper.standardOutput = eventPipe
        helper.standardError = FileHandle.nullDevice

        eventPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        helper.terminationHandler = { [weak self] process in
            eventPipe.fileHandleForReading.readabilityHandler = nil
            self?.helperExited(process)
        }

        Self.exclusiveFlag.store(true, ordering: .sequentiallyConsistent)
        endedCleanly = false
        pendingLine.removeAll()
        do {
            try helper.run()
        }
        catch {
            Self.exclusiveFlag.store(false, ordering: .sequentiallyConsistent)
            throw HelperError(errorDescription: String(localized: "無法啟動輔助程序：\(error.localizedDescription)"))
        }
        process = helper
        input = commandPipe.fileHandleForWriting
    }

    private func send(_ command: HelperCommand) {
        lock.lock()
        let handle = input
        lock.unlock()
        guard var data = try? JSONEncoder().encode(command) else { return }
        data.append(UInt8(ascii: "\n"))
        try? handle?.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        lock.lock()
        pendingLine.append(data)
        var events = [HelperEvent]()
        while let end = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
            if let event = try? JSONDecoder().decode(HelperEvent.self, from: pendingLine[pendingLine.startIndex..<end]) {
                events.append(event)
            }
            pendingLine.removeSubrange(pendingLine.startIndex...end)
        }
        lock.unlock()
        events.forEach(handle)
    }

    private func handle(_ event: HelperEvent) {
        switch event.kind {
        case .started:
            finishStart(error: nil)
        case .failed:
            markEnded()
            finishStart(error: event.message ?? String(localized: "無法開始播放"))
        case .track:
            guard let index = event.index, let sampleRate = event.sampleRate,
                  let bits = event.bitsPerSample, let frames = event.frameCount,
                  let path = event.outputPath.flatMap(OutputPath.init(rawValue:)) else { return }
            let format = AudioSourceFormat(sampleRate: sampleRate, bitsPerSample: bits, channels: 2, frameCount: frames)
            DispatchQueue.main.async { self.onTrackStarted?(index, format, path) }
        case .position:
            guard let index = event.index, let frame = event.frame else { return }
            DispatchQueue.main.async { self.onPosition?(index, frame) }
        case .trackFinished:
            let result = TrackResult(queueIndex: event.index ?? 0, passed: event.passed ?? false,
                                     matchedFile: event.matchedFile ?? false)
            DispatchQueue.main.async { self.onTrackFinished?(result) }
        case .queueFinished:
            let lastIndex = event.index ?? 0
            markEnded { self.onQueueFinished?(lastIndex) }
        case .interrupted:
            let reason = event.message ?? String(localized: "播放中斷")
            markEnded { self.onInterrupted?(reason) }
        case .suspended:
            lock.lock()
            endedCleanly = true
            suspended = (event.index ?? 0, event.frame ?? 0)
            lock.unlock()
        }
    }

    /// callback 等輔助程序退出才執行，App 看到的裝置狀態才會是還原後的
    private func markEnded(then callback: (() -> Void)? = nil) {
        lock.lock()
        endedCleanly = true
        endCallback = callback
        lock.unlock()
    }

    private func finishStart(error: String?) {
        lock.lock()
        startError = error
        let signal = startSignal
        startSignal = nil
        lock.unlock()
        signal?.signal()
    }

    private func helperExited(_ exited: Process) {
        lock.lock()
        guard process === exited else {
            lock.unlock()
            return
        }
        process = nil
        input = nil
        let clean = endedCleanly
        let signal = exitSignal
        let callback = endCallback
        exitSignal = nil
        endCallback = nil
        lock.unlock()

        if !clean { ExclusiveOutput.recoverStrandedDevices() }
        Self.exclusiveFlag.store(false, ordering: .sequentiallyConsistent)
        signal?.signal()
        if let callback { DispatchQueue.main.async(execute: callback) }
        if !clean {
            finishStart(error: String(localized: "輔助程序意外結束"))
            DispatchQueue.main.async { self.onInterrupted?(String(localized: "輔助程序意外結束")) }
        }
    }
}
