//
//  NowPlayingPublisher.swift
//  LosslessCompanion
//
//  媒體鍵、控制中心與鎖定畫面。閒置時不宣告自己在播放，媒體鍵才會回到 Apple Music。
//

import AppKit
import Combine
import MediaPlayer

/// 歌曲資訊與播放狀態對應到系統欄位，沒有副作用，可以直接測試
enum NowPlayingSnapshot {
    static func info(item: QueueItem, status: PlaybackCoordinator.Status, elapsed: TimeInterval) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyAlbumTitle: item.album,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
    }

    static func playbackState(for status: PlaybackCoordinator.Status) -> MPNowPlayingPlaybackState {
        switch status {
        case .idle: return .stopped
        case .paused: return .paused
        case .preparing, .playing: return .playing
        }
    }
}

final class NowPlayingPublisher {
    private let player: PlaybackCoordinator
    private let center = MPNowPlayingInfoCenter.default()
    private var cancellables = Set<AnyCancellable>()
    private var artwork: MPMediaItemArtwork?
    private var artworkItemID: String?

    /// 系統會自己推算進度，只要定期校正，拖動也會在這段時間內反映
    private static let elapsedSyncInterval = 5
    private static let artworkSide: CGFloat = 600

    init(player: PlaybackCoordinator) {
        self.player = player
        connectCommands()

        Publishers.CombineLatest(player.$status.removeDuplicates(), player.$currentIndex.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.publish() }
            .store(in: &cancellables)

        player.clock.$elapsed
            .throttle(for: .seconds(Self.elapsedSyncInterval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
    }

    private func connectCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.handle { $0.togglePause() } ?? .commandFailed }
        commands.playCommand.addTarget { [weak self] _ in
            self?.handle { if $0.status == .paused { $0.togglePause() } } ?? .commandFailed
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.handle { if $0.status == .playing { $0.togglePause() } } ?? .commandFailed
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.handle { $0.next() } ?? .commandFailed }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.handle { $0.previous() } ?? .commandFailed }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return self?.handle { $0.seek(to: position) } ?? .commandFailed
        }
    }

    private func handle(_ action: (PlaybackCoordinator) -> Void) -> MPRemoteCommandHandlerStatus {
        guard player.status != .idle else { return .noActionableNowPlayingItem }
        action(player)
        return .success
    }

    private func publish() {
        guard player.status != .idle, let item = player.currentItem else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = NowPlayingSnapshot.info(item: item, status: player.status, elapsed: player.clock.elapsed)
        if artworkItemID == item.id, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        else {
            loadArtwork(for: item)
        }
        center.nowPlayingInfo = info
        center.playbackState = NowPlayingSnapshot.playbackState(for: player.status)
    }

    private func loadArtwork(for item: QueueItem) {
        artworkItemID = item.id
        artwork = nil
        Task { @MainActor [weak self] in
            guard let image = await ArtworkStore.shared.image(for: item.artworkSource, side: Self.artworkSide),
                  let self, self.artworkItemID == item.id else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publish()
        }
    }
}
