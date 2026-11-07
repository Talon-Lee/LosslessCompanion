//
//  StreamPathStatus.swift
//  LosslessCompanion
//
//  把串流路徑上每個會改動聲音的地方列出來。這裡的結果代表「沒有處理」，不代表 Bit-Perfect：
//  Music 不獨佔，最後由系統把浮點轉成 DAC 的整數，那一步軟體看不到。
//

import AppKit
import CoreAudio
import Foundation

struct MusicProcessing: Equatable {
    var volume = 100
    var isMuted = false
    var isEQEnabled = false
    var isAirPlay = false
    var trackAdjustment = 0
    var trackEQ = ""
}

struct StreamDeviceState: Equatable {
    var sampleRate: Double
    var bitDepth: Int
    var isInteger: Bool
    var isPhysical: Bool
    var transport: String
    var volume: Float?
    var isMuted = false
}

enum StreamCheckState {
    case ok
    case warning
    case unknown
}

struct StreamCheckRow: Identifiable, Equatable {
    let title: String
    let value: String
    let state: StreamCheckState

    var id: String { title }
}

enum StreamVerdict: Equatable {
    case processed
    case unknown
    case cleanPath
    case samplesUnchanged
    case matchesFile

    var title: String {
        switch self {
        case .processed: return String(localized: "串流經過處理")
        case .unknown: return String(localized: "Apple Music 串流")
        case .cleanPath: return String(localized: "無處理路徑")
        case .samplesUnchanged: return String(localized: "樣本未改動")
        case .matchesFile: return String(localized: "與本地檔相同")
        }
    }
}

struct StreamPathStatus: Equatable {
    private static let fullVolume: Float = 0.995

    var format: StreamFormat?
    var device: StreamDeviceState?
    var music: MusicProcessing?
    var soundCheck: Bool?
    var transitions: Bool?
    var soundEnhancer: Bool?
    var overloads = 0
    var switchTime: TimeInterval?

    /// 路徑本身的檢查。其他 App 的混音、樣本與末端不顯示：串流本來就改不了系統混音，本地播放也不會經過
    func pathRows(deviceName: String) -> [StreamCheckRow] {
        [codecRow, deviceFormatRow, volumeRow, processingRow, outputRow(deviceName: deviceName), interruptionRow]
    }

    /// 第一個有問題的項目，給播放列的警告用
    func firstProblem(deviceName: String, sampling: StreamSamplingState) -> String? {
        pathRows(deviceName: deviceName).first { $0.state == .warning }.map { "\($0.title)：\($0.value)" }
    }

    func verdict(deviceName: String, sampling: StreamSamplingState) -> StreamVerdict {
        let states = pathRows(deviceName: deviceName).map(\.state)
        if states.contains(.warning) { return .processed }
        if states.contains(.unknown) { return .unknown }
        return .cleanPath
    }

    private var codecRow: StreamCheckRow {
        let title = String(localized: "編碼")
        guard let format else { return StreamCheckRow(title: title, value: String(localized: "尚未偵測"), state: .unknown) }
        if let codec = format.lossyCodec {
            return StreamCheckRow(title: title, value: String(localized: "\(codec)，有損"), state: .warning)
        }
        return StreamCheckRow(title: title, value: "ALAC \(Format.quality(rate: format.sampleRate, bits: format.bitDepth))", state: .ok)
    }

    private var deviceFormatRow: StreamCheckRow {
        let title = String(localized: "DAC 格式")
        guard let device else { return StreamCheckRow(title: title, value: String(localized: "未知"), state: .unknown) }
        let kind = device.isInteger ? String(localized: "整數") : String(localized: "浮點")
        let value = "\(Format.sampleRate(device.sampleRate)) / \(device.bitDepth)-bit \(kind)"
        guard let format else { return StreamCheckRow(title: title, value: value, state: .unknown) }
        if device.sampleRate != format.sampleRate {
            return StreamCheckRow(title: title, value: String(localized: "\(Format.sampleRate(device.sampleRate))，與歌曲不同"), state: .warning)
        }
        if format.isLossless, device.bitDepth < format.bitDepth {
            return StreamCheckRow(title: title, value: String(localized: "\(device.bitDepth)-bit，低於歌曲"), state: .warning)
        }
        return StreamCheckRow(title: title, value: value, state: .ok)
    }

    private var volumeRow: StreamCheckRow {
        let title = String(localized: "音量")
        guard let music, let device else { return StreamCheckRow(title: title, value: String(localized: "未知"), state: .unknown) }
        let value = "Music \(music.volume) · DAC \(Format.deviceVolume(device.volume))"
        let isFull = music.volume == 100 && !music.isMuted && !device.isMuted && (device.volume ?? 1) >= Self.fullVolume
        return StreamCheckRow(title: title, value: value, state: isFull ? .ok : .warning)
    }

    private var processingRow: StreamCheckRow {
        let title = String(localized: "音效")
        var active = [String]()
        if music?.isEQEnabled == true { active.append("EQ") }
        if music?.trackEQ.isEmpty == false { active.append(String(localized: "單曲 EQ")) }
        if music.map({ $0.trackAdjustment != 0 }) == true { active.append(String(localized: "單曲音量")) }
        if soundCheck == true { active.append("Sound Check") }
        if transitions == true { active.append(String(localized: "淡入淡出")) }
        if soundEnhancer == true { active.append("Sound Enhancer") }
        if !active.isEmpty { return StreamCheckRow(title: title, value: active.joined(separator: "、"), state: .warning) }
        if music == nil || soundCheck == nil || transitions == nil || soundEnhancer == nil {
            return StreamCheckRow(title: title, value: String(localized: "未知"), state: .unknown)
        }
        return StreamCheckRow(title: title, value: String(localized: "全部關閉"), state: .ok)
    }

    private func outputRow(deviceName: String) -> StreamCheckRow {
        let title = String(localized: "裝置")
        if music?.isAirPlay == true { return StreamCheckRow(title: title, value: "AirPlay", state: .warning) }
        guard let device else { return StreamCheckRow(title: title, value: deviceName, state: .unknown) }
        return StreamCheckRow(title: title, value: "\(deviceName) · \(device.transport)", state: device.isPhysical ? .ok : .warning)
    }

    private var interruptionRow: StreamCheckRow {
        var value = String(localized: "\(overloads) 次")
        if let switchTime { value += String(localized: " · 切換 \(Int((switchTime * 1000).rounded())) ms") }
        return StreamCheckRow(title: String(localized: "中斷"), value: value, state: overloads == 0 ? .ok : .warning)
    }
}

/// 冷啟動時 Music 先播幾秒 AAC，同一首換成 ALAC 時要從頭重播，整首才都是無損
struct LossyStartTracker {
    /// 已經播了這麼久就不重播，避免把使用者聽到一半的歌拉回開頭
    static let replayLimit: TimeInterval = 15

    private var lossyTrackID: String??

    mutating func trackChanged() {
        lossyTrackID = nil
    }

    /// 回傳 true 代表要從頭重播
    mutating func formatSeen(_ format: StreamFormat, trackID: String?) -> Bool {
        if !format.isLossless {
            lossyTrackID = .some(trackID)
            return false
        }
        defer { lossyTrackID = nil }
        return lossyTrackID == .some(trackID)
    }
}

/// 播放列上的警告要持續兩次檢查才出現，換歌時 DAC 切換的短暫不符不算
struct StreamWarningFilter {
    private(set) var warning: String?
    private var pending: String?

    mutating func update(_ problem: String?) {
        if problem == nil || problem == pending { warning = problem }
        pending = problem
    }
}

enum StreamPathProbe {
    private static let musicDomain = "com.apple.Music" as CFString

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func unsigned(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func device(uid: String) -> StreamDeviceState? {
        guard let device = AudioDeviceLookup.device(forUID: uid),
              let stream = objects(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).first else { return nil }
        var address = address(kAudioStreamPropertyPhysicalFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return nil }
        let (transport, isPhysical) = describeTransport(unsigned(device, kAudioDevicePropertyTransportType) ?? 0)
        return StreamDeviceState(sampleRate: DeviceRate.nominal(of: device),
                                 bitDepth: Int(format.mBitsPerChannel),
                                 isInteger: format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                                 isPhysical: isPhysical,
                                 transport: transport,
                                 volume: ExclusiveOutput.volume(deviceUID: uid),
                                 isMuted: unsigned(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput) == 1)
    }

    private static func describeTransport(_ type: UInt32) -> (String, Bool) {
        switch type {
        case kAudioDeviceTransportTypeUSB: return ("USB", true)
        case kAudioDeviceTransportTypeBuiltIn: return (String(localized: "內建"), true)
        case kAudioDeviceTransportTypeHDMI: return ("HDMI", true)
        case kAudioDeviceTransportTypeDisplayPort: return ("DisplayPort", true)
        case kAudioDeviceTransportTypeThunderbolt: return ("Thunderbolt", true)
        case kAudioDeviceTransportTypePCI: return ("PCI", true)
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return (String(localized: "藍牙"), false)
        case kAudioDeviceTransportTypeAirPlay: return ("AirPlay", false)
        case kAudioDeviceTransportTypeAggregate: return (String(localized: "聚集裝置"), false)
        case kAudioDeviceTransportTypeVirtual: return (String(localized: "虛擬裝置"), false)
        default: return (String(localized: "未知"), true)
        }
    }

    /// Music 的偏好設定；沒有這個鍵時是 nil
    static func musicPreference(_ key: String) -> Bool? {
        CFPreferencesAppSynchronize(musicDomain)
        return (CFPreferencesCopyAppValue(key as CFString, musicDomain) as? NSNumber)?.boolValue
    }
}
