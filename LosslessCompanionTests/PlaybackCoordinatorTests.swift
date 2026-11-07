//
//  PlaybackCoordinatorTests.swift
//  LosslessCompanionTests
//

import XCTest
@testable import LosslessCompanion

final class PlaybackCoordinatorTests: XCTestCase {
    private var local: FakeLocal!
    private var stream: FakeStream!
    private var clock: TestClock!
    private var player: PlaybackCoordinator!
    private var events: [String]!
    private var timers: [(delay: TimeInterval, item: DispatchWorkItem)]!

    private let format = AudioSourceFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2, frameCount: 8_820_000)

    override func setUp() {
        local = FakeLocal()
        stream = FakeStream()
        clock = TestClock()
        events = []
        local.log = { [unowned self] in self.events.append($0) }
        stream.log = { [unowned self] in self.events.append($0) }
        let testClock = clock!
        timers = []
        player = PlaybackCoordinator(local: local, stream: stream, deviceUID: { "DAC" }, now: { testClock.date },
                                     schedule: { [unowned self] delay, item in self.timers.append((delay, item)) })
    }

    private func fireLastTimer() {
        guard let timer = timers.last, !timer.item.isCancelled else { return }
        timer.item.perform()
    }

    private func settle() {
        clock.advance(3)
    }

    private func startLocal(_ items: [QueueItem], at index: Int = 0) {
        player.play(items: items, startIndex: index)
        local.finishPlay()
        local.onTrackStarted?(0, format, .directInteger)
    }

    func testConsecutiveLocalTracksShareOneEngineRun() {
        startLocal([localItem("a"), localItem("b"), localItem("c"), streamItem("d", trackID: "D")])

        XCTAssertEqual(local.playedRuns, [["a", "b", "c"]])
        XCTAssertEqual(player.status, .playing)
        XCTAssertEqual(player.activeRoute, .local)
        XCTAssertEqual(player.outputPath, .directInteger)
    }

    func testEnqueueWhileIdleStartsPlaying() {
        player.enqueue([localItem("a")])
        local.finishPlay()

        XCTAssertEqual(local.playedRuns, [["a"]])
        XCTAssertEqual(player.currentItem?.title, "a")
    }

    func testEnqueueExtendsTheEngineRun() {
        startLocal([localItem("a"), localItem("b")])

        player.enqueue([localItem("c")])

        XCTAssertEqual(local.playedRuns, [["a", "b"]])
        XCTAssertEqual(local.upcoming.map(\.after), [0])
        XCTAssertEqual(local.upcoming.map(\.titles), [["b", "c"]])
        XCTAssertEqual(player.queue.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(player.currentItem?.title, "a")
    }

    /// 引擎剛結束時才加入，它沒有收到新歌，回報的最後一首還是舊的
    func testTrackAddedAsTheEngineFinishesStillPlays() {
        startLocal([localItem("a")])
        player.enqueue([localItem("b")])

        local.onFinished?(0)
        local.finishPlay()

        XCTAssertEqual(local.playedRuns, [["a"], ["b"]])
        XCTAssertEqual(player.currentItem?.title, "b")
    }

    func testEnqueuedStreamFollowsLocalTrack() {
        startLocal([localItem("a")])
        player.enqueue([streamItem("b", trackID: "B")])

        local.onFinished?(0)

        XCTAssertEqual(player.currentItem?.title, "b")
        XCTAssertEqual(player.activeRoute, .appleMusic)
    }

    func testEnqueueNothingChangesNothing() {
        player.enqueue([])
        XCTAssertEqual(player.status, .idle)
    }

    func testMusicJumpingAwayBeforeItStartsCountsAsStuck() {
        var stuck = 0
        player.isMusicOutputStuck = { true }
        player.onMusicStuck = { stuck += 1 }
        startStream([streamItem("a", trackID: "A"), streamItem("b", trackID: "B")])

        stream.onProgress?(0, "X")

        XCTAssertEqual(stuck, 1)
        XCTAssertEqual(player.currentItem?.title, "a")
        XCTAssertNotEqual(player.status, .idle)
    }

    func testChangingTrackInMusicWhileItsOutputRunsStillReleasesTheQueue() {
        var stuck = 0
        player.isMusicOutputStuck = { false }
        player.onMusicStuck = { stuck += 1 }
        startStream([streamItem("a", trackID: "A")])

        stream.onProgress?(0, "X")

        XCTAssertEqual(stuck, 0)
        XCTAssertEqual(player.status, .idle)
    }

    func testChangingTrackAfterPlaybackStartedIsNeverStuck() {
        var stuck = 0
        player.isMusicOutputStuck = { true }
        player.onMusicStuck = { stuck += 1 }
        startStream([streamItem("a", trackID: "A")])
        stream.onProgress?(5, "A")

        stream.onProgress?(0, "X")

        XCTAssertEqual(stuck, 0)
        XCTAssertEqual(player.status, .idle)
    }

    func testRestartResumesTheSameTrack() {
        startStream([streamItem("a", trackID: "A"), streamItem("b", trackID: "B")])
        stream.played.removeAll()

        XCTAssertTrue(player.musicWillRestart())
        XCTAssertEqual(player.status, .preparing)
        XCTAssertNotNil(player.message)
        player.musicDidRestart()

        XCTAssertEqual(stream.played.map(\.trackID), ["A"])
        XCTAssertEqual(player.currentItem?.title, "a")
        XCTAssertEqual(player.queue.count, 2)
        XCTAssertNil(player.message)
    }

    func testMusicStillLoadingAfterRestartIsNotStuckAgain() {
        var stuck = 0
        player.isMusicOutputStuck = { true }
        player.onMusicStuck = { stuck += 1 }
        startStream([streamItem("a", trackID: "A")])
        XCTAssertTrue(player.musicWillRestart())
        player.musicDidRestart()
        stream.finishPlay()
        clock.advance(3)

        stream.onProgress?(0, "OLD")

        XCTAssertEqual(stuck, 0)
        XCTAssertEqual(player.currentItem?.title, "a")
        XCTAssertNotEqual(player.status, .idle)

        clock.advance(10)
        stream.onProgress?(0, "OLD")

        XCTAssertEqual(stuck, 1)
    }

    func testRestartReturnsToThePositionOnceMusicIsReallyPlaying() {
        startStream([streamItem("a", trackID: "A")])
        stream.onProgress?(30, "A")

        XCTAssertTrue(player.musicWillRestart())
        player.musicDidRestart()
        stream.finishPlay()
        settle()
        XCTAssertTrue(stream.seeks.isEmpty)
        stream.onProgress?(1.5, "A")

        XCTAssertEqual(stream.seeks, [30])
        XCTAssertEqual(player.clock.elapsed, 30)
    }

    func testRestartWithNothingStreamingHasNothingToResume() {
        startLocal([localItem("a")])

        XCTAssertFalse(player.musicWillRestart())
        player.musicDidRestart()

        XCTAssertTrue(stream.played.isEmpty)
    }

    func testMusicNoticesDuringRestartAreIgnored() {
        startStream([streamItem("a", trackID: "A")])
        XCTAssertTrue(player.musicWillRestart())
        settle()

        stream.onEvent?(.stopped)
        stream.onProgress?(0, "X")

        XCTAssertEqual(player.status, .preparing)
        XCTAssertEqual(player.currentItem?.title, "a")
    }

    func testStoppingDuringRestartDoesNotResume() {
        startStream([streamItem("a", trackID: "A")])
        stream.played.removeAll()
        XCTAssertTrue(player.musicWillRestart())

        player.stop()
        player.musicDidRestart()

        XCTAssertTrue(stream.played.isEmpty)
        XCTAssertEqual(player.status, .idle)
    }

    func testChoosingAnotherTrackDuringRestartWins() {
        startStream([streamItem("a", trackID: "A"), streamItem("b", trackID: "B")])
        XCTAssertTrue(player.musicWillRestart())
        stream.played.removeAll()

        player.next()
        player.musicDidRestart()

        XCTAssertEqual(stream.played.map(\.trackID), ["B"])
        XCTAssertEqual(player.currentItem?.title, "b")
    }

    func testRestartNoteOnlyShowsWhenNothingIsPlaying() {
        player.noteMusicRestarted()
        XCTAssertNotNil(player.message)

        startLocal([localItem("a")])
        player.noteMusicRestarted()
        XCTAssertNil(player.message)
    }

    func testPlayNextGoesRightAfterTheCurrentTrack() {
        startLocal([localItem("a"), localItem("b")])

        player.playNext([localItem("x"), localItem("y")])

        XCTAssertEqual(player.queue.map(\.title), ["a", "x", "y", "b"])
        XCTAssertEqual(player.currentItem?.title, "a")
        XCTAssertEqual(local.playedRuns, [["a", "b"]])
        XCTAssertEqual(local.upcoming.map(\.after), [0])
        XCTAssertEqual(local.upcoming.map(\.titles), [["x", "y", "b"]])
    }

    func testEngineIndexesFollowTheInsertedTracks() {
        startLocal([localItem("a"), localItem("b")])
        player.playNext([localItem("x")])

        local.onTrackStarted?(1, format, .directInteger)
        XCTAssertEqual(player.currentItem?.title, "x")

        local.onTrackStarted?(2, format, .directInteger)
        XCTAssertEqual(player.currentItem?.title, "b")

        local.onFinished?(2)
        XCTAssertEqual(player.status, .idle)
    }

    func testPlayNextUsesTheTrackThatIsPlayingNow() {
        startLocal([localItem("a"), localItem("b"), localItem("c")])
        local.onTrackStarted?(1, format, .directInteger)

        player.playNext([localItem("x")])

        XCTAssertEqual(player.queue.map(\.title), ["a", "b", "x", "c"])
        XCTAssertEqual(local.upcoming.map(\.after), [1])
        XCTAssertEqual(local.upcoming.map(\.titles), [["x", "c"]])
    }

    func testPlayNextInRunStartedMidQueueIsRelativeToTheRun() {
        startLocal([streamItem("s", trackID: "S"), localItem("a"), localItem("b")], at: 1)

        player.playNext([localItem("x")])

        XCTAssertEqual(local.upcoming.map(\.after), [0])
        XCTAssertEqual(local.upcoming.map(\.titles), [["x", "b"]])
        local.onTrackStarted?(1, format, .directInteger)
        XCTAssertEqual(player.currentItem?.title, "x")
    }

    func testPlayNextWhileIdleStartsPlaying() {
        player.playNext([localItem("a")])
        local.finishPlay()

        XCTAssertEqual(local.playedRuns, [["a"]])
        XCTAssertEqual(player.currentItem?.title, "a")
    }

    func testPlayNextNothingChangesNothing() {
        startLocal([localItem("a")])

        player.playNext([])

        XCTAssertTrue(local.upcoming.isEmpty)
    }

    func testStreamPlayedNextEndsTheEngineRunAtTheCurrentTrack() {
        startLocal([localItem("a"), localItem("b")])

        player.playNext([streamItem("x", trackID: "X")])

        XCTAssertEqual(local.upcoming.map(\.titles), [[]])
        local.onFinished?(0)
        XCTAssertEqual(player.currentItem?.title, "x")
        XCTAssertEqual(player.activeRoute, .appleMusic)
    }

    func testLocalPlayedNextDuringStreamWaitsForItsTurn() {
        startStream([streamItem("a", trackID: "A"), streamItem("b", trackID: "B")])

        player.playNext([localItem("x")])

        XCTAssertEqual(player.queue.map(\.title), ["a", "x", "b"])
        XCTAssertTrue(local.upcoming.isEmpty)
        XCTAssertTrue(local.playedRuns.isEmpty)
    }

    func testRepeatOneKeepsRepeatingAfterPlayNext() {
        player.repeatMode = .one
        startLocal([localItem("a")])

        player.playNext([localItem("x")])

        XCTAssertEqual(local.upcoming.map(\.titles), [[]])
        local.onFinished?(0)
        XCTAssertEqual(local.playedRuns, [["a"], ["a"]])
    }

    func testTrackAddedWhileMusicIsReleasingTheDACIsPartOfTheRun() {
        stream.completesPauseImmediately = false
        player.play(items: [localItem("a")], startIndex: 0)

        player.playNext([localItem("x")])

        XCTAssertTrue(local.upcoming.isEmpty)
        stream.pauseCompletion?()
        XCTAssertEqual(local.playedRuns, [["a", "x"]])
    }

    func testTrackAddedAfterEndTimerIsArmedStillPlays() {
        startStream([streamItem("a", trackID: "A", seconds: 100)])
        stream.onProgress?(98, "A")

        player.enqueue([streamItem("b", trackID: "B")])
        fireLastTimer()

        XCTAssertEqual(player.currentItem?.title, "b")
        XCTAssertEqual(stream.played.last?.trackID, "B")
    }

    func testNextInsideRunSkipsWithoutRestartingEngine() {
        startLocal([localItem("a"), localItem("b")])

        player.next()

        XCTAssertEqual(local.skips, [1])
        XCTAssertEqual(local.playedRuns.count, 1)
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testEngineReportsNextTrackInRun() {
        startLocal([localItem("a"), localItem("b")])

        local.onTrackStarted?(1, format, .directInteger)

        XCTAssertEqual(player.currentIndex, 1)
    }

    func testLocalToStreamWaitsForDACRelease() {
        startLocal([localItem("a"), streamItem("b", trackID: "B")])
        events.removeAll()
        local.onFinished?(0)
        player.next()
        local.stopCompletion?()

        XCTAssertEqual(stream.played.last?.trackID, "B")
        XCTAssertEqual(player.currentItem?.title, "b")
    }

    func testJumpFromLocalToStreamStopsEngineBeforeMusicPlays() {
        startLocal([localItem("a"), streamItem("b", trackID: "B")])
        events.removeAll()

        player.next()
        XCTAssertEqual(events, ["local.stop"], "Music must not start before the DAC is released")
        XCTAssertTrue(stream.played.isEmpty)

        local.finishStop()
        XCTAssertEqual(events, ["local.stop", "local.stopped", "stream.play"])

        stream.finishPlay()
        XCTAssertEqual(player.status, .playing)
        XCTAssertTrue(stream.polling)
    }

    func testStreamToLocalWaitsForMusicToPause() {
        stream.completesPauseImmediately = false
        player.play(items: [streamItem("a", trackID: "A"), localItem("b")], startIndex: 0)
        stream.finishPlay()
        events.removeAll()

        player.next()
        XCTAssertEqual(events, ["stream.pause"], "exclusive access must wait until Music stops")
        XCTAssertFalse(stream.polling)

        stream.pauseCompletion?()
        XCTAssertEqual(events, ["stream.pause", "local.play"])
    }

    private func startStream(_ items: [QueueItem]) {
        player.play(items: items, startIndex: 0)
        stream.finishPlay()
        settle()
    }

    func testStreamNearEndStartsNextTrackBeforeMusicMovesOn() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])

        stream.onProgress?(98, "A")
        XCTAssertEqual(timers.last?.delay ?? -1, 1.55, accuracy: 0.001)
        XCTAssertEqual(stream.played.count, 1)

        fireLastTimer()

        XCTAssertEqual(stream.played.last?.trackID, "B")
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testNewerPositionReplacesEndTimer() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(98, "A")
        let first = timers.last?.item

        stream.onProgress?(99, "A")

        XCTAssertEqual(first?.isCancelled, true)
        XCTAssertEqual(timers.last?.delay ?? -1, 0.55, accuracy: 0.001)
    }

    func testLastTrackPausesMusicBeforeAutoplay() {
        startStream([streamItem("a", trackID: "A", seconds: 100)])
        stream.onProgress?(99, "A")
        XCTAssertEqual(timers.last?.delay ?? -1, 0.75, accuracy: 0.001)
        events.removeAll()

        fireLastTimer()

        XCTAssertEqual(events, ["stream.pause"])
        XCTAssertEqual(player.status, .idle)
    }

    func testStreamToLocalAtEndHandsOverDAC() {
        startStream([streamItem("a", trackID: "A", seconds: 100), localItem("b")])
        stream.onProgress?(99, "A")
        events.removeAll()

        fireLastTimer()

        XCTAssertEqual(events, ["stream.pause", "local.play"])
    }

    func testRepeatOneRestartsStream() {
        player.repeatMode = .one
        startStream([streamItem("a", trackID: "A", seconds: 100)])
        stream.onProgress?(99, "A")

        fireLastTimer()

        XCTAssertEqual(stream.played.count, 2)
        XCTAssertEqual(stream.played.last?.trackID, "A")
    }

    func testSeekingBackCancelsEndTimer() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(99, "A")

        player.seek(to: 10)

        XCTAssertEqual(timers.last?.item.isCancelled, true)
    }

    func testPausingInMusicCancelsEndTimer() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(99, "A")

        stream.onEvent?(.paused(trackID: "A"))

        XCTAssertEqual(player.status, .paused)
        XCTAssertEqual(timers.last?.item.isCancelled, true)
        XCTAssertEqual(stream.played.count, 1)
    }

    func testAutoplayTrackNearEndMovesToNextItem() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(98.5, "A")

        stream.onProgress?(1, "AUTOPLAY")

        XCTAssertEqual(stream.played.last?.trackID, "B")
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testOtherTrackMidSongFromPollingReleasesQueue() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(30, "A")

        stream.onProgress?(1, "OTHER")

        XCTAssertEqual(player.status, .idle)
        XCTAssertEqual(stream.played.count, 1)
    }

    func testPreviousTrackPositionIsIgnoredWhileMusicSwitches() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(98, "A")
        fireLastTimer()
        stream.finishPlay()

        stream.onProgress?(99, "A")

        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(stream.played.count, 2)
    }

    func testStopNearEndWithAutoplayOffAdvances() {
        startStream([streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")])
        stream.onProgress?(98, "A")

        stream.onEvent?(.stopped)

        XCTAssertEqual(stream.played.last?.trackID, "B")
    }

    func testStopWhileMusicIsStillLaunchingKeepsQueue() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")], startIndex: 0)
        stream.finishPlay()
        settle()

        stream.onEvent?(.stopped)
        stream.onEvent?(.paused(trackID: "A"))

        XCTAssertEqual(player.status, .playing)
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testPlayIsResentWhenMusicDropsItWhileLaunching() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100)], startIndex: 0)
        stream.finishPlay()
        stream.isStopped = true

        fireLastTimer()

        XCTAssertEqual(stream.played.count, 2)
        XCTAssertEqual(player.status, .playing)
    }

    func testBufferingMusicIsNotInterrupted() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100)], startIndex: 0)
        stream.finishPlay()

        fireLastTimer()

        XCTAssertEqual(stream.played.count, 1)
        XCTAssertEqual(timers.count, 2, "keeps waiting")
    }

    func testConfirmedPlaybackNeedsNoRetry() {
        startStream([streamItem("a", trackID: "A", seconds: 100)])
        stream.onProgress?(1.5, "A")
        stream.isStopped = true

        fireLastTimer()

        XCTAssertEqual(stream.played.count, 1)
    }

    func testGivesUpAfterRepeatedDrops() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100)], startIndex: 0)
        stream.isStopped = true
        for _ in 0..<4 {
            stream.finishPlay()
            fireLastTimer()
        }

        XCTAssertEqual(stream.played.count, 4)
        XCTAssertEqual(player.status, .idle)
        XCTAssertNotNil(player.message)
    }

    func testStopLongAfterStartIsBelieved() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100)], startIndex: 0)
        stream.finishPlay()
        clock.advance(11)

        stream.onEvent?(.stopped)

        XCTAssertEqual(player.status, .idle)
    }

    func testPausingInMusicMidSongIsMirrored() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100)], startIndex: 0)
        stream.finishPlay()
        settle()
        stream.onProgress?(30, "A")

        stream.onEvent?(.paused(trackID: "A"))
        XCTAssertEqual(player.status, .paused)

        stream.onEvent?(.playing(trackID: "A"))
        XCTAssertEqual(player.status, .playing)
    }

    func testStoppingInMusicMidSongReleasesQueue() {
        player.play(items: [streamItem("a", trackID: "A", seconds: 100), streamItem("b", trackID: "B")], startIndex: 0)
        stream.finishPlay()
        settle()
        stream.onProgress?(30, "A")

        stream.onEvent?(.stopped)

        XCTAssertEqual(player.status, .idle)
        XCTAssertEqual(stream.played.count, 1)
    }

    func testPlayingAnotherSongInMusicReleasesQueue() {
        player.play(items: [streamItem("a", trackID: "A")], startIndex: 0)
        stream.finishPlay()
        settle()

        stream.onEvent?(.playing(trackID: "OTHER"))

        XCTAssertEqual(player.status, .idle)
        XCTAssertFalse(stream.polling)
        XCTAssertNotNil(player.message)
    }

    func testOwnMusicEventsAreIgnoredWhileSettling() {
        startLocal([localItem("a")])

        stream.onEvent?(.playing(trackID: "X"))

        XCTAssertEqual(player.status, .playing)
        XCTAssertTrue(events.filter { $0 == "local.stop" }.isEmpty)
    }

    func testPressingPlayInMusicDuringLocalHandsDACBack() {
        startLocal([localItem("a"), localItem("b")])
        settle()

        stream.onEvent?(.playing(trackID: "X"))

        XCTAssertEqual(player.status, .idle)
        XCTAssertTrue(events.contains("local.stop"))
    }

    func testStaleLocalStartIsIgnoredAfterSwitching() {
        player.play(items: [localItem("a"), streamItem("b", trackID: "B")], startIndex: 0)
        let staleStart = local.playCompletion
        player.jump(to: 1)
        local.finishStop()
        stream.finishPlay()

        staleStart?(nil)

        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.activeRoute, .appleMusic)
    }

    func testFailedLocalFallsBackToStream() {
        struct Failure: Error {}
        player.play(items: [localItem("a", stream: true)], startIndex: 0)

        local.finishPlay(Failure())

        XCTAssertEqual(stream.played.count, 1)
        XCTAssertEqual(player.currentItem?.route, .appleMusic)
        XCTAssertNotNil(player.message)
    }

    func testFailedLocalWithoutStreamStops() {
        struct Failure: Error {}
        player.play(items: [localItem("a")], startIndex: 0)

        local.finishPlay(Failure())

        XCTAssertEqual(player.status, .idle)
    }

    func testRepeatedStreamFailuresStopInsteadOfRunningThroughPlaylist() {
        struct Failure: Error {}
        let items = (0..<6).map { streamItem("s\($0)", trackID: "A\($0)") }
        player.play(items: items, startIndex: 0)

        for _ in 0..<3 { stream.finishPlay(Failure()) }

        XCTAssertEqual(stream.played.count, 3)
        XCTAssertEqual(player.status, .idle)
    }

    func testMissingAutomationPermissionStopsImmediately() {
        let items = (0..<3).map { streamItem("s\($0)", trackID: "A\($0)") }
        player.play(items: items, startIndex: 0)

        stream.finishPlay(MusicScriptError.notAuthorized)

        XCTAssertEqual(stream.played.count, 1)
        XCTAssertEqual(player.status, .idle)
        XCTAssertNotNil(player.message)
    }

    func testPreviousRestartsTrackAfterThreeSeconds() {
        startLocal([localItem("a"), localItem("b")])
        player.next()
        local.onPosition?(1, 44_100 * 10)

        player.previous()

        XCTAssertEqual(local.seeks, [0])
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testRepeatOnePlaysSingleTrackRun() {
        player.repeatMode = .one
        startLocal([localItem("a"), localItem("b")])

        local.onFinished?(0)

        XCTAssertEqual(local.playedRuns, [["a"], ["a"]])
    }

    func testRepeatAllWrapsToStart() {
        player.repeatMode = .all
        startLocal([localItem("a"), localItem("b")])

        local.onFinished?(1)

        XCTAssertEqual(local.playedRuns.count, 2)
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testQueueEndGoesIdle() {
        startLocal([localItem("a")])

        local.onFinished?(0)

        XCTAssertEqual(player.status, .idle)
        XCTAssertNil(player.currentItem)
    }

    func testStopDuringHandoffDoesNotStartMusic() {
        startLocal([localItem("a"), streamItem("b", trackID: "B")])
        player.next()

        player.stop()
        local.finishStop()

        XCTAssertTrue(stream.played.isEmpty)
        XCTAssertEqual(player.status, .idle)
    }

    func testTerminationWaitsForDACRelease() {
        startLocal([localItem("a")])
        events.removeAll()

        player.stopForTermination()

        XCTAssertEqual(events, ["local.stopAndWait"])
    }

    func testPausingLocalNeverTouchesMusic() {
        startLocal([localItem("a")])
        events.removeAll()

        player.togglePause()

        XCTAssertEqual(local.pausedStates, [true])
        XCTAssertTrue(events.isEmpty)
    }

    func testResumingLocalPausesMusicFirst() {
        startLocal([localItem("a")])
        player.togglePause()
        stream.completesPauseImmediately = false

        player.togglePause()
        XCTAssertEqual(local.pausedStates, [true], "must wait for Music before resuming exclusive output")

        stream.pauseCompletion?()
        XCTAssertEqual(local.pausedStates, [true, false])
    }

    func testVerificationIsReported() {
        startLocal([localItem("a")])

        local.onVerified?(0, TrackResult(queueIndex: 0, passed: true, matchedFile: true))

        XCTAssertEqual(player.lastVerification, TrackVerification(title: "a", passed: true, matchedFile: true))
    }

    // MARK: - Play counts

    private func position(_ seconds: Double, index: Int = 0, on local: FakeLocal) {
        local.onPosition?(index, Int64(seconds * 44_100))
    }

    func testPlayCountsAfterHalfOfTheSong() {
        var counted = [String]()
        player.onLocalPlayCounted = { counted.append($0.title) }
        player.play(items: [localItem("A", seconds: 200)], startIndex: 0)
        local.finishPlay()
        stride(from: 0.0, through: 99.0, by: 1).forEach { position($0, on: local) }
        XCTAssertTrue(counted.isEmpty)
        position(100, on: local)
        XCTAssertEqual(counted, ["A"])
    }

    func testPlayCountIsRecordedOnce() {
        var counted = [String]()
        player.onLocalPlayCounted = { counted.append($0.title) }
        player.play(items: [localItem("A", seconds: 200)], startIndex: 0)
        local.finishPlay()
        stride(from: 0.0, through: 150.0, by: 1).forEach { position($0, on: local) }
        XCTAssertEqual(counted, ["A"])
    }

    func testLongSongCountsAfterFourMinutes() {
        var counted = [String]()
        player.onLocalPlayCounted = { counted.append($0.title) }
        player.play(items: [localItem("Long", seconds: 1_000)], startIndex: 0)
        local.finishPlay()
        stride(from: 0.0, through: 239.0, by: 1).forEach { position($0, on: local) }
        XCTAssertTrue(counted.isEmpty)
        position(240, on: local)
        XCTAssertEqual(counted, ["Long"])
    }

    func testSeekingDoesNotCount() {
        var counted = [String]()
        player.onLocalPlayCounted = { counted.append($0.title) }
        player.play(items: [localItem("A", seconds: 200)], startIndex: 0)
        local.finishPlay()
        position(1, on: local)
        position(190, on: local)
        position(191, on: local)
        XCTAssertTrue(counted.isEmpty)
    }

    func testNextTrackStartsItsOwnCount() {
        var counted = [String]()
        player.onLocalPlayCounted = { counted.append($0.title) }
        player.play(items: [localItem("A", seconds: 200), localItem("B", seconds: 200)], startIndex: 0)
        local.finishPlay()
        stride(from: 0.0, through: 120.0, by: 1).forEach { position($0, on: local) }
        local.onTrackStarted?(1, makeTrack(title: "B").format, .directInteger)
        stride(from: 0.0, through: 120.0, by: 1).forEach { position($0, index: 1, on: local) }
        XCTAssertEqual(counted, ["A", "B"])
    }

    // MARK: - Finished queue

    func testQueueIsClearedWhenEverythingHasPlayed() {
        player.play(items: [localItem("A"), localItem("B")], startIndex: 0)
        local.finishPlay()
        local.onFinished?(1)
        XCTAssertEqual(player.status, .idle)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testRepeatAllKeepsQueue() {
        player.repeatMode = .all
        player.play(items: [localItem("A")], startIndex: 0)
        local.finishPlay()
        local.onFinished?(0)
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertNotEqual(player.status, .idle)
    }

    func testStoppingKeepsQueueSoItCanBeRestarted() {
        player.play(items: [localItem("A"), localItem("B")], startIndex: 0)
        local.finishPlay()
        player.stop()
        XCTAssertEqual(player.queue.count, 2)
        XCTAssertNil(player.currentIndex)
    }

    func testClearUpcomingKeepsCurrentAndPlayed() {
        player.play(items: ["A", "B", "C", "D"].map { localItem($0) }, startIndex: 1)
        local.finishPlay()
        player.clearUpcoming()
        XCTAssertEqual(player.queue.map(\.title), ["A", "B"])
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.status, .playing)
        XCTAssertEqual(local.upcoming.last?.titles, [])
    }

    func testPlaybackEndsAfterCurrentSongOnceUpcomingIsCleared() {
        player.play(items: ["A", "B", "C"].map { localItem($0) }, startIndex: 0)
        local.finishPlay()
        player.clearUpcoming()
        local.onFinished?(0)
        XCTAssertEqual(player.status, .idle)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testAddingAfterClearingPlaysNext() {
        player.play(items: ["A", "B"].map { localItem($0) }, startIndex: 0)
        local.finishPlay()
        player.clearUpcoming()
        player.enqueue([localItem("C")])
        XCTAssertEqual(player.queue.map(\.title), ["A", "C"])
        XCTAssertEqual(local.upcoming.last?.titles, ["C"])
    }

    func testClearWhileStoppedEmptiesEverything() {
        player.play(items: ["A", "B"].map { localItem($0) }, startIndex: 0)
        local.finishPlay()
        player.stop()
        player.clearUpcoming()
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testStreamStopsAtEndOnceUpcomingIsCleared() {
        player.play(items: [streamItem("A", trackID: "AA"), streamItem("B", trackID: "BB")], startIndex: 0)
        stream.finishPlay()
        player.clearUpcoming()
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertEqual(player.status, .playing)
    }

    func testRemovingUpcomingSongUpdatesEngine() {
        startLocal(["A", "B", "C"].map { localItem($0) })
        player.remove(at: 1)
        XCTAssertEqual(player.queue.map(\.title), ["A", "C"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(local.upcoming.last?.after, 0)
        XCTAssertEqual(local.upcoming.last?.titles, ["C"])
    }

    func testCurrentSongCannotBeRemoved() {
        startLocal(["A", "B"].map { localItem($0) })
        player.remove(at: 0)
        XCTAssertEqual(player.queue.count, 2)
        XCTAssertTrue(local.upcoming.isEmpty)
    }

    func testRemovingPlayedSongKeepsCurrentAndLeavesEngineAlone() {
        startLocal(["A", "B", "C", "D"].map { localItem($0) })
        local.onTrackStarted?(2, format, .directInteger)
        player.remove(at: 0)
        XCTAssertEqual(player.queue.map(\.title), ["B", "C", "D"])
        XCTAssertEqual(player.currentItem?.title, "C")
        XCTAssertTrue(local.upcoming.isEmpty)

        // 引擎的索引還是原本的，播到下一首要對回正確的歌
        local.onTrackStarted?(3, format, .directInteger)
        XCTAssertEqual(player.currentItem?.title, "D")
    }

    func testRemovingPlayedSongKeepsLaterEngineCommandsAligned() {
        startLocal(["A", "B", "C", "D"].map { localItem($0) })
        local.onTrackStarted?(2, format, .directInteger)
        player.remove(at: 1)

        player.enqueue([localItem("E")])
        XCTAssertEqual(local.upcoming.last?.after, 2)
        XCTAssertEqual(local.upcoming.last?.titles, ["D", "E"])

        player.jump(to: 2)
        XCTAssertEqual(local.skips, [3])
        XCTAssertEqual(player.currentItem?.title, "D")
    }

    func testPlayedSongBeforeRemovedOneRestartsInsteadOfSkippingToWrongTrack() {
        startLocal(["A", "B", "C", "D"].map { localItem($0) })
        local.onTrackStarted?(2, format, .directInteger)
        player.remove(at: 1)

        player.jump(to: 0)
        XCTAssertTrue(local.skips.isEmpty)
        local.finishStop()
        XCTAssertEqual(player.currentItem?.title, "A")
        XCTAssertEqual(local.playedRuns.last, ["A", "C", "D"])
    }

    func testPlayedSongAfterRemovedOneCanStillSkipBack() {
        startLocal(["A", "B", "C", "D"].map { localItem($0) })
        local.onTrackStarted?(3, format, .directInteger)
        player.remove(at: 0)

        player.jump(to: 0)
        XCTAssertEqual(local.skips, [1])
        XCTAssertEqual(player.currentItem?.title, "B")
    }

    func testRemovingSongPlayedBeforeTheRunShiftsTheRun() {
        player.play(items: [streamItem("S", trackID: "SS"), localItem("A"), localItem("B")], startIndex: 1)
        local.finishPlay()
        local.onTrackStarted?(0, format, .directInteger)
        player.remove(at: 0)
        XCTAssertEqual(player.currentItem?.title, "A")

        local.onTrackStarted?(1, format, .directInteger)
        XCTAssertEqual(player.currentItem?.title, "B")
    }

    func testVerificationOfRemovedSongIsIgnored() {
        startLocal(["A", "B", "C"].map { localItem($0) })
        local.onTrackStarted?(1, format, .directInteger)
        player.remove(at: 0)
        local.onVerified?(0, TrackResult(queueIndex: 0, passed: true, matchedFile: true))
        XCTAssertNil(player.lastVerification)
    }

    func testEngineFinishAfterRemovingPlayedSongEndsAtTheRightPlace() {
        startLocal(["A", "B"].map { localItem($0) })
        local.onTrackStarted?(1, format, .directInteger)
        player.remove(at: 0)
        local.onFinished?(1)
        XCTAssertEqual(player.status, .idle)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testRemovingWhileStoppedJustShortensQueue() {
        startLocal(["A", "B"].map { localItem($0) })
        player.stop()
        player.remove(at: 0)
        XCTAssertEqual(player.queue.map(\.title), ["B"])
        XCTAssertNil(player.currentIndex)
    }

    func testRemovingPlayedSongDuringStreamStillAdvancesAtEnd() {
        player.play(items: [streamItem("A", trackID: "AA"), streamItem("B", trackID: "BB")], startIndex: 1)
        stream.finishPlay()
        player.enqueue([streamItem("C", trackID: "CC")])
        settle()
        stream.onProgress?(198, "BB")
        player.remove(at: 0)
        fireLastTimer()
        XCTAssertEqual(player.currentItem?.title, "C")
    }

    func testMovingUpcomingSongUpdatesEngineOrder() {
        startLocal(["A", "B", "C", "D"].map { localItem($0) })
        player.moveUpcoming(from: 3, to: 1)
        XCTAssertEqual(player.queue.map(\.title), ["A", "D", "B", "C"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(local.upcoming.last?.titles, ["D", "B", "C"])

        player.moveUpcoming(from: 1, to: 3)
        XCTAssertEqual(player.queue.map(\.title), ["A", "B", "C", "D"])
    }

    func testPlayedAndCurrentSongsCannotBeMoved() {
        startLocal(["A", "B", "C", "D"].map { localItem($0) })
        local.onTrackStarted?(1, format, .directInteger)
        for (source, destination) in [(0, 2), (1, 2), (3, 1), (3, 0), (2, 2), (2, 9)] {
            player.moveUpcoming(from: source, to: destination)
        }
        XCTAssertEqual(player.queue.map(\.title), ["A", "B", "C", "D"])
        XCTAssertTrue(local.upcoming.isEmpty)
    }

    func testMovingStreamSongInFrontOfLocalShortensEngineRun() {
        startLocal([localItem("A"), localItem("B"), streamItem("S", trackID: "SS")])
        player.moveUpcoming(from: 2, to: 1)
        XCTAssertEqual(local.upcoming.last?.titles, [])
        local.onFinished?(0)
        local.finishStop()
        XCTAssertEqual(player.currentItem?.title, "S")
    }

    func testMovingWhileStoppedReordersEverything() {
        startLocal(["A", "B", "C"].map { localItem($0) })
        player.stop()
        player.moveUpcoming(from: 0, to: 2)
        XCTAssertEqual(player.queue.map(\.title), ["B", "C", "A"])
    }

    func testFailureKeepsQueue() {
        player.play(items: [localItem("A"), localItem("B")], startIndex: 0)
        local.finishPlay(BitPerfectError.decodeFailed(-1))
        XCTAssertEqual(player.status, .idle)
        XCTAssertEqual(player.queue.count, 2)
    }
}

final class QueueBuilderTests: XCTestCase {
    private let entries = [
        makeEntry(0, title: "local"),
        makeEntry(1, title: "stream"),
        makeEntry(2, title: "gone", cloud: "no longer available"),
        makeEntry(3, title: "local-gone", cloud: "no longer available"),
    ]

    private var playlist: MusicPlaylist {
        MusicPlaylist(id: "AA", name: "P", isSmart: false, isSubscription: false, entries: entries)
    }

    private func match(_ entry: MusicPlaylistEntry) -> LibraryTrack? {
        entry.title.hasPrefix("local") ? makeTrack(title: entry.title) : nil
    }

    func testPreferLocalKeepsPlaylistOrderAndSkipsUnavailable() {
        let built = QueueBuilder.items(for: playlist, startingAt: nil, preference: .preferLocal, match: match)

        XCTAssertEqual(built.items.map(\.title), ["local", "stream", "local-gone"])
        XCTAssertEqual(built.items.map(\.route), [.local, .appleMusic, .local])
    }

    func testLocalOnlyDropsStreamTracks() {
        let built = QueueBuilder.items(for: playlist, startingAt: entries[3], preference: .localOnly, match: match)

        XCTAssertEqual(built.items.map(\.title), ["local", "local-gone"])
        XCTAssertEqual(built.index, 1)
    }

    func testAppleMusicOnlyIgnoresLocalFiles() {
        let built = QueueBuilder.items(for: playlist, startingAt: nil, preference: .appleMusicOnly, match: match)

        XCTAssertEqual(built.items.map(\.title), ["local", "stream"])
        XCTAssertTrue(built.items.allSatisfy { $0.route == .appleMusic })
    }

    func testForcedRouteOverridesOnlyTheChosenTrack() {
        let built = QueueBuilder.items(for: playlist, startingAt: entries[0], preference: .preferLocal,
                                       forcedRoute: .appleMusic, match: match)

        XCTAssertEqual(built.items[0].route, .appleMusic)
        XCTAssertEqual(built.items[2].route, .local)
    }

    func testForcingUnavailableTrackToStreamKeepsLocal() {
        let built = QueueBuilder.items(for: playlist, startingAt: entries[3], preference: .preferLocal,
                                       forcedRoute: .appleMusic, match: match)

        XCTAssertEqual(built.items[built.index].route, .local)
    }
}

final class MusicRestartPolicyTests: XCTestCase {
    func testStopsRestartingWhenItDoesNotHelp() {
        var policy = MusicRestartPolicy()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(policy.allowsRestart(at: start))
        XCTAssertTrue(policy.allowsRestart(at: start.addingTimeInterval(30)))
        XCTAssertFalse(policy.allowsRestart(at: start.addingTimeInterval(60)))
    }

    func testAllowsAgainAfterItWorkedForAWhile() {
        var policy = MusicRestartPolicy()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = policy.allowsRestart(at: start)
        _ = policy.allowsRestart(at: start.addingTimeInterval(30))

        XCTAssertTrue(policy.allowsRestart(at: start.addingTimeInterval(200)))
    }
}

final class QueueSectionsTests: XCTestCase {
    func testMiddleOfQueue() {
        let sections = QueueSections(count: 5, currentIndex: 2)
        XCTAssertEqual(sections.played, 0..<2)
        XCTAssertEqual(sections.current, 2)
        XCTAssertEqual(sections.upcoming, 3..<5)
    }

    func testFirstAndLast() {
        XCTAssertTrue(QueueSections(count: 3, currentIndex: 0).played.isEmpty)
        XCTAssertTrue(QueueSections(count: 3, currentIndex: 2).upcoming.isEmpty)
    }

    func testNothingPlayingShowsEverythingAsUpcoming() {
        let sections = QueueSections(count: 3, currentIndex: nil)
        XCTAssertNil(sections.current)
        XCTAssertTrue(sections.played.isEmpty)
        XCTAssertEqual(sections.upcoming, 0..<3)
    }

    func testIndexOutsideQueueIsIgnored() {
        XCTAssertNil(QueueSections(count: 2, currentIndex: 5).current)
    }

    func testDropIndexFollowsRowHeightAndStaysInUpcoming() {
        let sections = QueueSections(count: 6, currentIndex: 1)
        XCTAssertEqual(sections.dropIndex(from: 3, offset: 20, rowHeight: 48), 3)
        XCTAssertEqual(sections.dropIndex(from: 3, offset: 30, rowHeight: 48), 4)
        XCTAssertEqual(sections.dropIndex(from: 3, offset: -50, rowHeight: 48), 2)
        XCTAssertEqual(sections.dropIndex(from: 3, offset: 900, rowHeight: 48), 5)
        XCTAssertEqual(sections.dropIndex(from: 3, offset: -900, rowHeight: 48), 2)
    }

    func testOtherRowsMakeRoomForDraggedRow() {
        XCTAssertEqual((2...6).map { QueueSections.shift(of: $0, draggingFrom: 3, to: 5) }, [0, 0, -1, -1, 0])
        XCTAssertEqual((1...5).map { QueueSections.shift(of: $0, draggingFrom: 4, to: 2) }, [0, 1, 1, 0, 0])
        XCTAssertEqual((1...5).map { QueueSections.shift(of: $0, draggingFrom: 3, to: 3) }, [0, 0, 0, 0, 0])
    }
}

final class PlaylistCoverageTests: XCTestCase {
    func testPercentRoundsDownSoIncompleteNeverShowsAll() {
        XCTAssertEqual(PlaylistCoverage.percent(999.0 / 1000), 99)
        XCTAssertEqual(PlaylistCoverage.percent(1), 100)
        XCTAssertEqual(PlaylistCoverage.percent(0), 0)
    }

    func testPercentOfExactValuesIsNotOffByOne() {
        for value in 0...100 {
            XCTAssertEqual(PlaylistCoverage.percent(Double(value) / 100), value)
        }
    }

    func testLibraryCountsEachSongOnceAndSkipsSubscriptions() {
        let library = [makeEntry(0, title: "a", id: "A"), makeEntry(1, title: "b", id: "B")]
        let own = MusicPlaylist(id: "P", name: "P", isSmart: false, isSubscription: false,
                                entries: [makeEntry(0, title: "b", id: "B"), makeEntry(1, title: "c", id: "C")])
        let subscription = MusicPlaylist(id: "S", name: "S", isSmart: false, isSubscription: true,
                                         entries: [makeEntry(0, title: "d", id: "D")])
        let coverage = PlaylistCoverage.library(library, playlists: [own, subscription]) { ["B", "C", "D"].contains($0) }
        XCTAssertEqual(coverage.total, 3)
        XCTAssertEqual(coverage.matched, 2)
    }

    func testEmptyLibraryHasZeroFraction() {
        XCTAssertEqual(PlaylistCoverage.library([], playlists: []) { _ in true }.fraction, 0)
    }
}
