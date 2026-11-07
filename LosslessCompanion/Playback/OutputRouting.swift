//
//  OutputRouting.swift
//  LosslessCompanion
//
//  獨佔 DAC 時 macOS 會把預設輸出移到內建喇叭，放開後才移回來。這段期間的預設輸出
//  不代表使用者的選擇，直接採用的話，下一段播放會跑到喇叭，音樂庫也會用喇叭的規格過濾。
//

import CoreAudio
import Foundation

/// 記住真正的輸出裝置，規則獨立出來才能測試
struct OutputMemory {
    private(set) var defaultUID: String?

    init(defaultUID: String?) {
        self.defaultUID = defaultUID
    }

    /// 回傳 true 代表裝置真的換了
    mutating func defaultChanged(to uid: String?, isExclusive: Bool) -> Bool {
        guard !isExclusive, let uid, uid != defaultUID else { return false }
        defaultUID = uid
        return true
    }

    func resolve(selected: String?, exists: (String) -> Bool) -> String? {
        if let selected, exists(selected) { return selected }
        return defaultUID
    }
}

final class OutputRouting {
    /// 主執行緒回呼
    var onDeviceChanged: (() -> Void)?

    private var memory = OutputMemory(defaultUID: AudioDeviceLookup.defaultOutputUID())
    private let settings: AppSettings
    private var listener: AudioObjectPropertyListenerBlock?

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    var currentUID: String? {
        memory.resolve(selected: settings.deviceUID) { AudioDeviceLookup.device(forUID: $0) != nil }
    }

    func startListening() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceChanged() }
        var address = Self.defaultDeviceAddress
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr else { return }
        listener = block
    }

    private func defaultDeviceChanged() {
        // 橋接時預設輸出是 Bridge，那不是使用者的選擇
        let isExclusive = BitPerfectClient.isExclusive || StreamBridgeClient.isActive
            || AudioDeviceLookup.defaultOutputUID() == StreamBridgeConstants.bridgeUID
        if memory.defaultChanged(to: AudioDeviceLookup.defaultOutputUID(), isExclusive: isExclusive) {
            onDeviceChanged?()
        }
    }

    deinit {
        guard let listener else { return }
        var address = Self.defaultDeviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
}
