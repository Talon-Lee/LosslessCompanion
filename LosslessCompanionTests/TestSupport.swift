//
//  TestSupport.swift
//  LosslessCompanionTests
//

import Foundation
@testable import LosslessCompanion

func makeTrack(title: String, artist: String = "Artist", album: String = "Album", number: Int = 1,
               seconds: Double = 200, rate: Double = 44_100, bits: Int = 16, path: String? = nil) -> LibraryTrack {
    LibraryTrack(path: path ?? "/music/\(artist)/\(album)/\(number) \(title).flac",
                 title: title, artist: artist, album: album, trackNumber: number, discNumber: 1,
                 sampleRate: rate, bitsPerSample: bits, frameCount: Int64(seconds * rate),
                 titleKey: SearchText.normalize(title), artistKey: SearchText.normalize(artist),
                 searchKey: SearchText.normalize(title + "\n" + artist + "\n" + album))
}

func makeEntry(_ position: Int = 0, title: String, artist: String = "Artist", album: String = "Album", number: Int = 1,
               seconds: Double = 200, cloud: String = "subscription", id: String? = nil) -> MusicPlaylistEntry {
    MusicPlaylistEntry(position: position, trackID: id ?? String(format: "%016X", position + 1), title: title, artist: artist,
                       albumArtist: "", album: album, duration: seconds, trackNumber: number, discNumber: 1, year: 2020,
                       cloudStatus: cloud)
}

func localItem(_ name: String, seconds: Double = 200, stream: Bool = false) -> QueueItem {
    let track = makeTrack(title: name, seconds: seconds)
    return QueueItem(id: name, title: name, artist: "A", album: "B", duration: seconds, route: .local, local: track,
                     stream: stream ? StreamReference(playlistID: "AA", trackID: "BB") : nil)
}

func streamItem(_ name: String, trackID: String, seconds: Double = 200) -> QueueItem {
    QueueItem(id: name, title: name, artist: "A", album: "B", duration: seconds, route: .appleMusic, local: nil,
              stream: StreamReference(playlistID: "AA", trackID: trackID))
}

final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// 記錄收到的指令，回呼由測試決定何時觸發，用來重現交接順序與延遲
final class FakeLocal: LocalTransport {
    var onTrackStarted: ((Int, AudioSourceFormat, OutputPath) -> Void)?
    var onPosition: ((Int, Int64) -> Void)?
    var onVerified: ((Int, TrackResult) -> Void)?
    var onFinished: ((Int) -> Void)?
    var onInterrupted: ((String) -> Void)?

    var log: (String) -> Void = { _ in }
    var playedRuns = [[String]]()
    var skips = [Int]()
    var upcoming = [(after: Int, titles: [String])]()
    var seeks = [Int64]()
    var pausedStates = [Bool]()
    var playCompletion: ((Error?) -> Void)?
    var stopCompletion: (() -> Void)?

    func play(tracks: [LibraryTrack], deviceUID: String, completion: @escaping (Error?) -> Void) {
        log("local.play")
        playedRuns.append(tracks.map(\.title))
        playCompletion = completion
    }
    func setPaused(_ paused: Bool) { pausedStates.append(paused) }
    func seek(toFrame frame: Int64) { seeks.append(frame) }
    func skip(toIndex index: Int) { skips.append(index) }
    func replaceUpcoming(after index: Int, with tracks: [LibraryTrack]) { upcoming.append((index, tracks.map(\.title))) }
    func stop(completion: @escaping () -> Void) {
        log("local.stop")
        stopCompletion = completion
    }
    func stopAndWait() { log("local.stopAndWait") }
    func finishPlay(_ error: Error? = nil) {
        let completion = playCompletion
        playCompletion = nil
        completion?(error)
    }
    func finishStop() {
        log("local.stopped")
        let completion = stopCompletion
        stopCompletion = nil
        completion?()
    }
}

final class FakeStream: StreamTransport {
    var onEvent: ((StreamEvent) -> Void)?
    var onProgress: ((TimeInterval, String?) -> Void)?

    var log: (String) -> Void = { _ in }
    var played = [StreamReference]()
    var resumes = 0
    var seeks = [TimeInterval]()
    var polling = false
    var playCompletion: ((Error?) -> Void)?
    var pauseCompletion: (() -> Void)?
    var completesPauseImmediately = true
    var isStopped = false

    func play(_ reference: StreamReference, completion: @escaping (Error?) -> Void) {
        log("stream.play")
        played.append(reference)
        playCompletion = completion
    }
    func resume() { resumes += 1 }
    func pauseIfPlaying(completion: @escaping () -> Void) {
        log("stream.pause")
        if completesPauseImmediately { completion() }
        else { pauseCompletion = completion }
    }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func setPositionPolling(_ enabled: Bool) { polling = enabled }
    func finishPlay(_ error: Error? = nil) {
        let completion = playCompletion
        playCompletion = nil
        completion?(error)
    }
}
