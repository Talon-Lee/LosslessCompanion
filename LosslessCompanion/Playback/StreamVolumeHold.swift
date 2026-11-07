//
//  StreamVolumeHold.swift
//  LosslessCompanion
//
//  串流不獨佔，DAC 音量沒有輔助程序替它拉高與還原，由 App 自己記住原本的值。
//  App 被強制結束時不會還原，和輔助程序被 kill -9 一樣會停在 100%。
//

import Foundation

final class StreamVolumeHold {
    private let raise: (String) -> [DeviceVolume]
    private let restore: ([DeviceVolume], String) -> Void
    private var held: (uid: String, volumes: [DeviceVolume])?

    init(raise: @escaping (String) -> [DeviceVolume] = ExclusiveOutput.raiseVolume(deviceUID:),
         restore: @escaping ([DeviceVolume], String) -> Void = ExclusiveOutput.restore(_:deviceUID:)) {
        self.raise = raise
        self.restore = restore
    }

    /// 傳入要拉高的裝置，nil 代表不需要；換裝置時先把原本那台還原
    func update(deviceUID: String?) {
        guard held?.uid != deviceUID else { return }
        release()
        if let deviceUID { held = (deviceUID, raise(deviceUID)) }
    }

    func release() {
        guard let held else { return }
        restore(held.volumes, held.uid)
        self.held = nil
    }
}
