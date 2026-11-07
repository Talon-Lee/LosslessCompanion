//
//  MusicFormatWatcher.swift
//  LosslessCompanion
//
//  即時掌握 Apple Music 接下來要輸出的規格，讓 DAC 能在歌曲最開頭就切好。
//  所有狀態都只在主執行緒存取。
//

import AppKit
import CoreAudio
import Foundation

struct StreamFormat: Equatable {
    let sampleRate: Double
    let bitDepth: Int
    /// 有損編碼的名稱；ALAC 是 nil
    let lossyCodec: String?

    var isLossless: Bool { lossyCodec == nil }

    /// 解析解碼器的日誌，例如
    /// "Input format: 2 ch,  96000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet"
    /// "Input format: 2 ch,  44100 Hz, aac  (0x00000000) 0 bits/channel, 0 bytes/packet"
    /// q 開頭的 qlac、qaac 是外層的解密包裝，真正的解碼器緊接在後面
    init?(logLine: String) {
        guard let input = logLine.range(of: "Input format:"),
              let channels = logLine.range(of: "ch, ", range: input.upperBound..<logLine.endIndex),
              let hertz = logLine.range(of: "Hz, ", range: channels.upperBound..<logLine.endIndex),
              let rate = Double(logLine[channels.upperBound..<hertz.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
        let codec = logLine[hertz.upperBound...].prefix { !$0.isWhitespace }
        sampleRate = rate
        if codec == "alac" {
            guard let source = logLine.range(of: "-bit source", range: hertz.upperBound..<logLine.endIndex),
                  let from = logLine.range(of: "from ", options: .backwards, range: hertz.upperBound..<source.lowerBound),
                  let bits = Int(logLine[from.upperBound..<source.lowerBound]) else { return nil }
            bitDepth = bits
            lossyCodec = nil
        }
        else if codec.hasPrefix("aac") {
            bitDepth = 0
            lossyCodec = "AAC"
        }
        else if codec.hasPrefix("ec-3") || codec.hasPrefix("ec+3") || codec.hasPrefix("ac-3") {
            bitDepth = 0
            lossyCodec = "Dolby"
        }
        else {
            return nil
        }
    }

    init(sampleRate: Double, bitDepth: Int, lossyCodec: String? = nil) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.lossyCodec = lossyCodec
    }
}

/// Music 日誌裡的其他線索。這些設定不在腳本字典裡，或只有日誌才看得到當下的值
enum MusicLogSignal: Equatable {
    case soundCheck(Bool)
    case soundEnhancer(Bool)
    case overload

    init?(logLine: String) {
        if let range = logLine.range(of: "inSoundCheckEnabled ") {
            self = .soundCheck(logLine[range.upperBound...].hasPrefix("1"))
        }
        else if logLine.contains("SoundEnhancerEffectsProcessor::SetSESettings") {
            self = .soundEnhancer(!logLine.contains("(disabled)"))
        }
        else if logLine.contains("skipping cycle due to overload") {
            self = .overload
        }
        else {
            return nil
        }
    }
}

/// 判斷日誌裡的規格屬於哪首歌。Music 會在歌曲中途預載下一首，所以只有換歌當下的規格才算數
struct MusicFormatTracker {
    /// 點歌或按下一首時，新歌的規格通常一秒多就出現，串流可能慢一些
    static let startWindow: TimeInterval = 4
    /// 自然換歌若要換取樣率，規格會緊貼著通知出現；再晚的都是預載下下一首
    static let naturalWindow: TimeInterval = 1.5
    /// 自然換歌的規格比通知略早，可往前回溯的時間
    static let lookBack: TimeInterval = 0.6

    private(set) var currentFormat: StreamFormat?
    private(set) var isPlaying = false

    /// 換歌後到新規格出現之前，currentFormat 還是上一首的
    var currentTrackFormat: StreamFormat? { formatTrackID == trackID ? currentFormat : nil }

    private var trackID: String?
    private var formatTrackID: String?
    private var stoppedAt: Date?
    private var windowEnd: Date?
    private var latest: (format: StreamFormat, date: Date)?
    private var preloaded: StreamFormat?

    mutating func playerStopped(at date: Date) {
        stoppedAt = date
        playerPaused()
    }

    mutating func playerPaused() {
        isPlaying = false
        windowEnd = nil
    }

    /// 回傳值不為 nil 時要立刻套用
    mutating func playerStartedPlaying(trackID id: String?, at date: Date) -> StreamFormat? {
        let isNewTrack = id != trackID
        guard !isPlaying || isNewTrack else { return nil } // Music 常連發兩次相同通知

        // 自然換歌時播放器沒有停過；點歌會先收到 Stopped，按下一首會先收到 Paused
        let isNatural = isPlaying && isNewTrack && !wasStoppedRecently(at: date)
        trackID = id
        isPlaying = true
        windowEnd = date.addingTimeInterval(isNatural ? Self.naturalWindow : Self.startWindow)

        if isNatural {
            if let latest, date.timeIntervalSince(latest.date) <= Self.lookBack {
                return accept(latest.format)
            }
            // 同取樣率的無縫換歌不會再出現規格，這時先前預載到的就是這首歌的規格
            return preloaded.map { accept($0) }
        }
        if isNewTrack { preloaded = nil }
        return nil
    }

    mutating func formatSeen(_ format: StreamFormat, at date: Date) -> StreamFormat? {
        latest = (format, date)
        if let windowEnd, date <= windowEnd {
            return accept(format)
        }
        if isPlaying {
            preloaded = format
        }
        return nil
    }

    private func wasStoppedRecently(at date: Date) -> Bool {
        guard let stoppedAt else { return false }
        return date.timeIntervalSince(stoppedAt) <= Self.lookBack
    }

    private mutating func accept(_ format: StreamFormat) -> StreamFormat {
        // 冷啟動時 Music 會先播一小段 AAC 再換成無損，有損的規格要繼續等
        if format.isLossless { windowEnd = nil }
        preloaded = nil
        currentFormat = format
        formatTrackID = trackID
        return format
    }
}

/// 判斷 Music 是不是卡在啟動輸出，時間與狀態都由呼叫端提供
struct MusicStallDetector {
    /// 正常情況下輸出一秒多就會啟動；Music 自己約 8 秒就放棄，所以要在那之前判斷
    static let threshold: TimeInterval = 6
    /// 兩次取樣之間位置變化小於這個值，才算沒有前進
    static let movementTolerance: TimeInterval = 0.1

    private(set) var isStalled = false
    private var waitingSince: Date?

    var isWaiting: Bool { waitingSince != nil || isStalled }

    mutating func musicStartedPlaying(at date: Date) {
        if waitingSince == nil { waitingSince = date }
    }

    /// 已判定卡住時要保留：Music 放棄播放後一樣還是壞的
    mutating func musicStoppedPlaying() {
        if !isStalled { waitingSince = nil }
    }

    func shouldConfirm(at date: Date) -> Bool {
        guard !isStalled, let waitingSince else { return false }
        return date.timeIntervalSince(waitingSince) >= Self.threshold
    }

    /// 回傳 true 代表這次才剛判定卡住；位置有前進就只是輸出不走這條路徑，例如 AirPlay
    mutating func confirm(firstPosition: Double, secondPosition: Double) -> Bool {
        guard !isStalled else { return false }
        if abs(secondPosition - firstPosition) < Self.movementTolerance {
            isStalled = true
            return true
        }
        waitingSince = nil
        return false
    }

    /// 回傳 true 代表先前判定卡住，現在恢復了
    mutating func outputStarted() -> Bool {
        let wasStalled = isStalled
        reset()
        return wasStalled
    }

    mutating func reset() {
        isStalled = false
        waitingSince = nil
    }
}

enum MusicAudioProcess {
    /// Music 自己的輸出是否已啟動；查不到時回傳 nil。只看裝置的話，別的 App 出聲也會被誤判
    static func isOutputRunning() -> Bool? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = app.processIdentifier
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        guard status == noErr, process != kAudioObjectUnknown else { return nil }

        address.mSelector = kAudioProcessPropertyIsRunningOutput
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}

/// 以 Music 的播放通知加上即時日誌驅動 MusicFormatTracker
final class MusicFormatWatcher: NSObject {
    /// 在主執行緒呼叫
    var onFormat: ((StreamFormat) -> Void)?
    var onPlaybackChanged: ((Bool) -> Void)?
    var onSignal: ((MusicLogSignal) -> Void)?
    var onTrackChanged: ((String?) -> Void)?

    var currentFormat: StreamFormat? { tracker.currentFormat }
    var currentTrackFormat: StreamFormat? { tracker.currentTrackFormat }
    var isMusicPlaying: Bool { tracker.isPlaying }

    private var tracker = MusicFormatTracker()
    private var lastTrackID: String?
    private var logStream: Process?
    private var pendingLine = Data()
    private var isStopping = false

    private static let restartDelay: TimeInterval = 2

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfoChanged(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"), object: nil, suspensionBehavior: .deliverImmediately
        )
        startLogStream()
    }

    func stop() {
        isStopping = true
        DistributedNotificationCenter.default().removeObserver(self)
        logStream?.terminate()
        logStream = nil
    }

    @objc private func playerInfoChanged(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let date = Date()
        switch info["Player State"] as? String {
        case "Playing":
            let persistentID = (info["PersistentID"] as? NSNumber).map(MusicScripts.hexIdentifier(from:))
            let id = persistentID ?? info["Name"] as? String
            if id != lastTrackID {
                lastTrackID = id
                onTrackChanged?(persistentID)
            }
            deliver(tracker.playerStartedPlaying(trackID: id, at: date))
            onPlaybackChanged?(true)
        case "Stopped":
            tracker.playerStopped(at: date)
            onPlaybackChanged?(false)
        default:
            tracker.playerPaused()
            onPlaybackChanged?(false)
        }
    }

    private func deliver(_ format: StreamFormat?) {
        if let format { onFormat?(format) }
    }

    /// `log stream` 的延遲只有幾毫秒；OSLogStore 每次都要重新查詢，趕不上歌曲開始
    private func startLogStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate",
                             "process == \"Music\" AND (eventMessage CONTAINS \"Input format\" OR eventMessage CONTAINS \"inSoundCheckEnabled\""
                             + " OR eventMessage CONTAINS \"SetSESettings\" OR eventMessage CONTAINS \"skipping cycle due to overload\")"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) {
                guard let self, !self.isStopping else { return }
                self.startLogStream()
            }
        }

        do {
            try process.run()
            logStream = process
        }
        catch {
            print("[MusicFormatWatcher] 無法啟動 log stream: \(error)")
        }
    }

    private func receive(_ data: Data) {
        pendingLine.append(data)
        while let end = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pendingLine[pendingLine.startIndex..<end], as: UTF8.self)
            pendingLine.removeSubrange(pendingLine.startIndex...end)
            if let format = StreamFormat(logLine: line) {
                deliver(tracker.formatSeen(format, at: Date()))
            }
            else if let signal = MusicLogSignal(logLine: line) {
                onSignal?(signal)
            }
        }
    }
}
