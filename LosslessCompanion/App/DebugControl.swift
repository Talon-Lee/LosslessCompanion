//
//  DebugControl.swift
//  LosslessCompanion
//
//  僅 Debug 組建：設定 LC_DEBUG_DIR 後，從該資料夾的 cmd 檔接收指令，並把狀態變化與 Music 的
//  原始通知寫進 events.log，用來實測播放流程。Release 不包含這段程式。
//

#if DEBUG
import AppKit
import Combine
import ImageIO

final class DebugControl: NSObject {
    static let shared = DebugControl()

    private var directory: URL?
    private var timer: Timer?
    private var model: AppModel { .shared }
    private var cancellables = Set<AnyCancellable>()
    private var logHandle: FileHandle?

    func start() {
        guard let path = ProcessInfo.processInfo.environment["LC_DEBUG_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        self.directory = directory
        let logURL = directory.appendingPathComponent("events.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observe()
    }

    private func observe() {
        let player = model.player
        player.$status.removeDuplicates().sink { [weak self] in self?.log("status \($0)") }.store(in: &cancellables)
        player.$currentIndex.removeDuplicates().sink { [weak self] in self?.log("index \($0.map(String.init) ?? "nil")") }.store(in: &cancellables)
        player.$outputPath.removeDuplicates().sink { [weak self] in self?.log("path \($0?.rawValue ?? "nil")") }.store(in: &cancellables)
        player.$message.removeDuplicates().sink { [weak self] in self?.log("message \($0 ?? "nil")") }.store(in: &cancellables)
        player.$lastVerification.removeDuplicates().sink { [weak self] value in
            guard let value else { return }
            self?.log("verified \(value.title) passed=\(value.passed) file=\(value.matchedFile)")
        }.store(in: &cancellables)
        model.$streamFormat.removeDuplicates().sink { [weak self] in
            self?.log("streamFormat \($0.map { "\($0.sampleRate)/\($0.bitDepth)" } ?? "nil")")
        }.store(in: &cancellables)
        model.$isMusicStalled.removeDuplicates().sink { [weak self] in self?.log("stalled \($0)") }.store(in: &cancellables)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfo(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"), object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func playerInfo(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let id = (info["PersistentID"] as? NSNumber).map(MusicScripts.hexIdentifier(from:)) ?? "-"
        let total = info["Total Time"] as? NSNumber
        log("music \(info["Player State"] as? String ?? "?") id=\(id) name=\(info["Name"] as? String ?? "-") total=\(total?.stringValue ?? "-")")
    }

    func log(_ text: String) {
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + text + "\n"
        logHandle?.write(Data(line.utf8))
    }

    private func poll() {
        guard let directory else { return }
        let url = directory.appendingPathComponent("cmd")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard let command = parts.first else { return }
        log("cmd \(parts.joined(separator: " "))")
        run(command, Array(parts.dropFirst()))
    }

    private func run(_ command: String, _ arguments: [String]) {
        let player = model.player
        switch command {
        case "summary":
            reply(summary())
            return
        case "streamcheck":
            model.refreshStreamPath()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                let rows = model.streamRows.map { "\($0.title): \($0.value) [\($0.state)]" }
                reply(["verdict": model.streamVerdict.title, "sampling": "\(model.streamSampling)", "rows": rows])
            }
            return
        case "page":
            open(page: arguments[0], argument: arguments.count > 1 ? arguments[1] : "")
        case "sort":
            let playlist = model.playlists.playlists[Int(arguments[0]) ?? 0]
            if let key = TrackSortKey(rawValue: arguments[1]) {
                model.settings.setTrackSort(TrackSort(key: key, ascending: arguments[2] == "asc"), for: playlist.id)
            }
        case "rows":
            let playlist = model.playlists.playlists[Int(arguments[0]) ?? 0]
            let rows = model.sortedEntries(of: playlist).prefix(Int(arguments[1]) ?? 8).map {
                "\($0.isFavorite == true ? "*" : " ") \($0.title) | \($0.artist) | \($0.album) | \($0.genre ?? "") | \($0.year)"
            }
            reply(["rows": Array(rows)])
            return
        case "list":
            reply(list(playlist: Int(arguments[0]) ?? 0, from: Int(arguments[1]) ?? 0, count: Int(arguments[2]) ?? 20))
            return
        case "pl":
            let playlist = model.playlists.playlists[Int(arguments[0]) ?? 0]
            let entry = playlist.entries[Int(arguments[1]) ?? 0]
            let route = arguments.count > 2 ? PlaybackRoute(rawValue: arguments[2]) : nil
            model.play(playlist, from: entry, forcedRoute: route)
        case "custom":
            let playlist = model.playlists.playlists[Int(arguments[0]) ?? 0]
            let items = arguments[1].split(separator: ",").compactMap { position -> QueueItem? in
                guard let position = Int(position) else { return nil }
                let entry = playlist.entries[position]
                let local = model.match(for: entry)?.track
                return QueueItem(entry: entry, playlistID: playlist.id, match: local, route: local == nil ? .appleMusic : .local)
            }
            player.play(items: items, startIndex: 0)
        case "pref":
            let playlist = model.playlists.playlists[Int(arguments[0]) ?? 0]
            if let preference = RoutePreference(rawValue: arguments[1]) { model.settings.setPreference(preference, for: playlist.id) }
        case "pause": player.togglePause()
        case "next": player.next()
        case "prev": player.previous()
        case "seek": player.seek(to: Double(arguments[0]) ?? 0)
        case "seekend": player.seek(to: player.clock.duration - (Double(arguments[0]) ?? 8))
        case "jump": player.jump(to: Int(arguments[0]) ?? 0)
        case "stop": player.stop()
        case "repeat": player.repeatMode = RepeatMode(rawValue: arguments[0]) ?? .off
        case "volume": model.musicVolume.set(Double(arguments[0]) ?? 100)
        case "appearance":
            model.settings.appearance = AppearanceMode(rawValue: arguments[0]) ?? .system
        case "artcheck":
            checkArtwork()
            return
        case "suggest":
            reply(suggestions(from: Int(arguments[0]) ?? 0, count: Int(arguments[1]) ?? 10))
            return
        case "rebuildtime":
            measureRebuild()
            return
        case "tagcheck":
            checkTags()
            return
        case "playfile":
            model.play(tracks: arguments.compactMap { try? LibraryInspector.inspect(url: URL(fileURLWithPath: $0)) })
        case "enqueuefile":
            model.enqueue(tracks: arguments.compactMap { try? LibraryInspector.inspect(url: URL(fileURLWithPath: $0)) })
        case "nextfile":
            model.playNext(tracks: arguments.compactMap { try? LibraryInspector.inspect(url: URL(fileURLWithPath: $0)) })
        case "localalbum":
            let playlist = model.playlists.playlists[Int(arguments[0]) ?? 0]
            reply(["rows": model.sortedEntries(of: playlist).compactMap { entry in
                model.localAlbum(for: entry).map { "\(entry.title) -> \($0.title) | \($0.artist)" }
            }.prefix(Int(arguments[1]) ?? 5).map { $0 }])
            return
        case "where":
            reply(["path": model.navigation.path.count, "top": model.navigation.path.last.map { "\($0)".prefix(40) }.map(String.init) ?? "main",
                   "showsPlayer": model.navigation.showsPlayer, "repeat": model.player.repeatMode.rawValue])
            return
        case "playrecent":
            model.play(model.index.recentMusic[Int(arguments[0]) ?? 0].playlist)
        case "musicrecent":
            reply(["albums": model.index.recentMusic.prefix(Int(arguments[0]) ?? 10).map {
                "\(Date(timeIntervalSince1970: $0.addedAt)) \($0.title) | \($0.artist) | \($0.playlist.entries.count)"
            }, "count": model.index.recentMusic.count])
            return
        case "addfolder":
            model.library.setFolders(model.library.folders + [arguments[0]])
        case "removefolder":
            model.library.setFolders(model.library.folders.filter { $0 != arguments[0] })
        case "library":
            reply(["folders": model.library.folders, "tracks": model.library.tracks.count, "scanning": model.library.isScanning,
                   "counts": model.library.folders.map { model.library.trackCount(in: $0) }])
            return
        case "scan":
            model.library.rescan { [weak self] in self?.reply(self?.albumList() ?? [:]) }
            return
        case "albums":
            reply(albumList())
            return
        case "musicfiles":
            model.refreshMusicFiles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.reply(["count": self.model.musicFilePaths.count, "sample": Array(self.model.musicFilePaths.prefix(3)),
                            // 參數可以傳一個路徑，檢查它是否被當成 Music 資料庫裡的檔案
                            "inMusic": arguments.first.map { self.model.musicFileCount(in: [$0]) } ?? 0])
            }
            return
        case "organize":
            organize(albumIndex: Int(arguments[0]) ?? 0)
            return
        case "merge":
            merge(target: Int(arguments[0]) ?? 0, source: Int(arguments[1]) ?? 1, movesFiles: arguments.count > 2)
            return
        case "undolast":
            guard let record = model.organizer.history.first else { return reply(["error": "no history"]) }
            model.undo(record) { [weak self] error in self?.reply(["undone": record.title, "error": error?.localizedDescription ?? ""]) }
            return
        case "addplay":
            model.albums[Int(arguments[0]) ?? 0].tracks.forEach { model.playCounts.recordPlay(of: $0.path) }
        case "exportalbum":
            exportAlbum(index: Int(arguments[0]) ?? 0, to: arguments[1])
            return
        case "fullscreen":
            toggleFullScreen(output: arguments.first)
            return
        case "chrome":
            reply(windowChrome(output: arguments.first))
            return
        case "click":
            click(x: Double(arguments[0]) ?? 0, fromTop: Double(arguments[1]) ?? 0)
            return
        case "drag":
            drag(x: Double(arguments[0]) ?? 0, fromTop: Double(arguments[1]) ?? 0, by: Double(arguments[2]) ?? 0)
            return
        case "windows":
            reply(["windows": NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) level=\($0.level.rawValue)" }])
            return
        case "bridge":
            let status = model.bridgeStatus
            reply(["active": StreamBridgeClient.isActive, "installed": StreamBridgeClient.isInstalled,
                   "enabled": model.settings.usesHogBridge,
                   "rate": status?.sampleRate ?? 0, "bits": status?.sourceBits ?? 0,
                   "phase": status?.phaseError ?? 0, "underruns": status?.underruns ?? 0, "gaps": status?.gaps ?? 0,
                   "problem": model.bridgeProblem ?? "", "default": AudioDeviceLookup.defaultOutputUID() ?? "",
                   "exclusive": BitPerfectClient.isExclusive])
            return
        case "queuelist":
            reply(["titles": player.queue.map(\.title), "current": player.currentIndex ?? -1])
            return
        case "queueremove":
            player.remove(at: Int(arguments[0]) ?? -1)
            reply(["titles": player.queue.map(\.title), "current": player.currentIndex ?? -1])
            return
        case "rightclick":
            reply(["ok": true])
            // 右鍵選單會卡住主執行緒直到關閉，先回覆，選單由輔助使用介面操作
            DispatchQueue.main.async { [weak self] in self?.rightClick(x: Double(arguments[0]) ?? 0, fromTop: Double(arguments[1]) ?? 0) }
            return
        case "quit":
            NSApp.terminate(nil)
            return
        default:
            break
        }
        reply(state())
    }

    private func albumList() -> [String: Any] {
        ["albums": model.albums.map { album -> [String: Any] in
            ["id": album.id, "title": album.title, "artist": album.artist,
             "tracks": album.tracks.map { track -> String in
                 let matched = model.appleEntries[track.path].map { "matched:\($0.title)" } ?? "unmatched"
                 return "\(track.path) | \(track.title) | \(track.artist) | \(track.album) | \(track.discNumber)-\(track.trackNumber) | plays=\(model.playCounts.count(for: track.path)) | \(matched)"
             }]
        }, "history": model.organizer.history.map { "\($0.title): \($0.summary)" }, "queue": model.player.queue.count]
    }

    private func organize(albumIndex: Int) {
        let album = model.albums[albumIndex]
        let rows = OrganizePlanner.rows(for: album.tracks, apple: model.appleEntries, source: .appleMusic,
                                        template: OrganizePlanner.defaultTemplate(for: album.tracks))
        var request = OrganizeRequest(title: "整理《\(album.title)》")
        request.moves = OrganizePlanner.moves(for: rows)
        request.tags = OrganizePlanner.tags(for: rows)
        let changes = rows.map { "\($0.stem): \($0.changes.joined(separator: " / "))" }
        model.organize(request) { [weak self] result in
            switch result {
            case .success(let outcome): self?.reply(["summary": outcome.record.summary, "failures": outcome.failures, "changes": changes])
            case .failure(let error): self?.reply(["error": error.localizedDescription, "changes": changes])
            }
        }
    }

    private func merge(target: Int, source: Int, movesFiles: Bool) {
        model.merge([model.albums[source]], into: model.albums[target], title: "合併測試", movesFiles: movesFiles) { [weak self] result in
            switch result {
            case .success(let outcome): self?.reply(["summary": outcome.record.summary, "failures": outcome.failures])
            case .failure(let error): self?.reply(["error": error.localizedDescription])
            }
        }
    }

    private var exportJob: ExportJob?
    private var exportObserver: AnyCancellable?

    private func exportAlbum(index: Int, to path: String) {
        let job = ExportJob(entries: ExportPlanner.entries(for: [model.albums[index]], playCounts: model.playCounts.records))
        exportJob = job
        exportObserver = job.$state.sink { [weak self] state in
            switch state {
            case .finished(let url): self?.reply(["exported": url.path, "size": job.totalSize])
            case .failed(let reason): self?.reply(["error": reason])
            default: break
            }
        }
        job.start(destination: URL(fileURLWithPath: path))
    }

    /// 把滑鼠事件直接送進視窗，不移動使用者的游標，用來確認標題列有沒有擋住底下的按鈕
    private func click(x: Double, fromTop: Double) {
        guard let window = NSApp.windows.first(where: \.canBecomeMain), let frame = window.contentView?.superview else { return }
        let location = NSPoint(x: x, y: frame.bounds.height - fromTop)
        let hit = frame.hitTest(location).map { "\(type(of: $0))" } ?? "nil"
        post(.leftMouseDown, at: location, in: window)
        // 同一瞬間按下放開時，點按手勢不會觸發
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.post(.leftMouseUp, at: location, in: window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.reply(["hit": hit, "repeat": self.model.player.repeatMode.rawValue, "showsQueue": self.model.navigation.showsQueue])
        }
    }

    /// 走 postEvent 才會成為 NSApp.currentEvent，SwiftUI 的手勢要靠它
    private func post(_ kind: NSEvent.EventType, at location: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    /// 按下、分段移動、放開，中間隔一點時間手勢才認得出是拖曳
    private func drag(x: Double, fromTop: Double, by distance: Double) {
        guard let window = NSApp.windows.first(where: \.canBecomeMain), let frame = window.contentView?.superview else { return }
        let start = NSPoint(x: x, y: frame.bounds.height - fromTop)
        let steps = 10
        post(.leftMouseDown, at: start, in: window)
        for step in 1...steps {
            let offset = distance * Double(step) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(step)) { [weak self] in
                self?.post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - offset), in: window)
            }
        }
        let end = NSPoint(x: start.x, y: start.y - distance)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(steps + 1)) { [weak self] in
            self?.post(.leftMouseUp, at: end, in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(steps + 1) + 0.4) { [weak self] in
            guard let self else { return }
            self.reply(["titles": self.model.player.queue.map(\.title), "current": self.model.player.currentIndex ?? -1])
        }
    }

    private func rightClick(x: Double, fromTop: Double) {
        guard let window = NSApp.windows.first(where: \.canBecomeMain), let frame = window.contentView?.superview else { return }
        let location = NSPoint(x: x, y: frame.bounds.height - fromTop)
        post(.rightMouseDown, at: location, in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.post(.rightMouseUp, at: location, in: window) }
    }

    /// 全螢幕時工具列在獨立的視窗裡，主視窗的圖片看不到，要逐一列出
    private func toggleFullScreen(output: String?) {
        guard let window = NSApp.windows.first(where: \.canBecomeMain) else { return reply(["error": "no window"]) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            var report = self.windowReport(main: window)
            if let output {
                for (index, other) in NSApp.windows.enumerated() where "\(type(of: other))".contains("Toolbar") {
                    guard let frame = other.contentView?.superview ?? other.contentView,
                          let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(output)-\(index).png"))
                    report["image"] = "\(output)-\(index).png"
                }
            }
            self.reply(report)
        }
    }

    private func windowReport(main: NSWindow) -> [String: Any] {
        func tree(_ view: NSView, depth: Int) -> [String] {
            let line = String(repeating: "  ", count: depth) + "\(type(of: view)) hidden=\(view.isHidden) alpha=\(view.alphaValue) frame=\(view.frame)"
            return [line] + (depth < 3 ? view.subviews.flatMap { tree($0, depth: depth + 1) } : [])
        }
        let options = NSApp.currentSystemPresentationOptions
        return ["windows": NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) alpha=\($0.alphaValue) frame=\($0.frame) level=\($0.level.rawValue)" },
                "fullScreen": main.styleMask.contains(.fullScreen),
                "autoHideToolbar": options.contains(.autoHideToolbar),
                "fullScreenOption": options.contains(.fullScreen),
                "toolbarVisible": main.toolbar?.isVisible ?? false,
                "layout": "\(main.contentLayoutRect)",
                "toolbarWindows": NSApp.windows.filter { "\(type(of: $0))".contains("Toolbar") }.flatMap { window in
                    (window.contentView?.superview ?? window.contentView).map { tree($0, depth: 0) } ?? []
                }]
    }

    /// 從關閉鈕往上列出每一層的顯示狀態，找出視窗按鈕被誰藏起來
    private func windowChrome(output: String?) -> [String: Any] {
        guard let window = NSApp.windows.first(where: \.canBecomeMain),
              let close = window.standardWindowButton(.closeButton) else { return ["error": "no window"] }
        func describe(_ view: NSView) -> String {
            "\(type(of: view)) hidden=\(view.isHidden) alpha=\(view.alphaValue) frame=\(view.frame)"
        }
        var chain = [String]()
        var view: NSView? = close
        while let current = view {
            chain.append(describe(current))
            view = current.superview
        }
        if let output, let frame = window.contentView?.superview,
           let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
        return ["chain": chain,
                "themeSubviews": window.contentView?.superview?.subviews.map(describe) ?? [],
                "style": window.styleMask.rawValue,
                "transparentTitlebar": window.titlebarAppearsTransparent,
                "titleVisibility": window.titleVisibility.rawValue,
                "toolbar": window.toolbar != nil,
                "toolbarVisible": window.toolbar?.isVisible ?? false]
    }

    private func open(page: String, argument: String) {
        let navigation = model.navigation
        switch page {
        case "playlist": navigation.open(.playlist(model.playlists.playlists[Int(argument) ?? 0].id))
        case "unmatched": navigation.open(.unmatched)
        case "musicrecent": navigation.open(.musicRecent)
        case "artist":
            let name = argument.replacingOccurrences(of: "_", with: " ")
            if let artist = model.index.artistsByName[name] { navigation.open(.artist(artist)) }
        case "musicalbum": navigation.open(.musicAlbum(model.index.recentMusic[Int(argument) ?? 0]))
        case "togglesidebar": NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        case "settings": navigation.open(.settings)
        case "review": navigation.review(model.reviewQueue)
        case "reviewclose": navigation.reviewRequest = nil
        case "genres": navigation.open(.genres)
        case "songs": navigation.open(.songs)
        case "albums": navigation.open(.albums)
        case "album": navigation.open(.album(model.albums[Int(argument) ?? 0]))
        case "queue": navigation.showsQueue.toggle()
        default: navigation.open(.home)
        }
    }

    /// 每一首都實際找封面並解碼，回報找不到或解不開的檔案
    private func checkArtwork() {
        let tracks = model.library.tracks
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lock = NSLock()
            var found = 0
            var missing = [String]()
            var undecodable = [String]()
            DispatchQueue.concurrentPerform(iterations: tracks.count) { index in
                let track = tracks[index]
                let data = TrackArtwork.data(for: track)
                let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
                lock.lock()
                if data == nil { missing.append(track.path) }
                else if !decoded { undecodable.append(track.path) }
                else { found += 1 }
                lock.unlock()
            }
            self?.reply(["tracks": tracks.count, "found": found, "missing": missing, "undecodable": undecodable])
        }
    }

    private func suggestions(from start: Int, count: Int) -> [String: Any] {
        let scored = model.reviewScores.values
        let queue = model.reviewQueue
        let rows = queue.dropFirst(start).prefix(count).map { track -> String in
            let top = model.suggester.suggestions(for: track, limit: 1).first
            let target = top.map { "\($0.score) \($0.entry.title) | \($0.entry.artist) | \($0.entry.album) | \($0.reasons.joined(separator: ","))" } ?? "-"
            let taken = top.flatMap { model.match(for: $0.entry) }.map { " TAKEN " + $0.track.path } ?? ""
            return "\(track.path) -> \(target)\(taken)"
        }
        let likely = queue.compactMap { model.suggester.suggestions(for: $0, limit: 1).first }.filter(\.isLikely)
        return ["suggested": scored.count,
                "likely": likely.count,
                "likelyTaken": likely.filter { model.match(for: $0.entry) != nil }.count,
                "certain": model.certainLinks(in: queue).count,
                "rows": Array(rows)]
    }

    /// 用新的標籤重算一次索引，和目前的結果比較；只計算，不寫入任何東西
    private func checkTags() {
        let tracks = model.library.tracks
        let addedAt = model.library.addedAt
        let decisions = model.review.decisions
        let before = model.index
        var seen = Set<String>()
        let entries = (model.playlists.library + model.playlists.playlists.flatMap(\.entries)).filter { seen.insert($0.trackID).inserted }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let updated = tracks.map { $0.updating(with: TrackMetadata.tags(for: $0.url)) }
            let pairs = zip(tracks, updated)
            let resolution = MatchResolver.resolve(tracks: updated, entries: entries, decisions: decisions)
            let index = LibraryIndex.build(tracks: updated, addedAt: addedAt, apple: resolution.apple, decisions: decisions)
            let names = Set(before.artists.map(\.name))
            let multiDisc = index.albums.filter { Set($0.tracks.map(\.discNumber)).count > 1 && $0.tracks.contains { !$0.path.hasSuffix(".flac") } }
            self?.reply([
                "discGained": pairs.filter { $0.discNumber != $1.discNumber }.count,
                "albumArtistGained": pairs.filter { $0.albumArtist != $1.albumArtist }.count,
                "artistFilled": pairs.filter { $0.artist.isEmpty && !$1.artist.isEmpty }.count,
                "flacChanged": pairs.filter { $0.path.hasSuffix(".flac") && ($0.artist != $1.artist || $0.discNumber != $1.discNumber || $0.albumArtist != $1.albumArtist) }.count,
                "stillNoArtist": updated.filter { $0.artist.isEmpty }.count,
                "multiLine": updated.filter { ($0.albumArtist ?? "").contains(where: \.isNewline) }.count,
                "albums": [before.albums.count, index.albums.count],
                "artists": [before.artists.count, index.artists.count],
                "compilations": [before.compilations.count, index.compilations.count],
                "unmatched": [before.unmatchedTracks.count, index.unmatchedTracks.count],
                "matches": resolution.matches.count,
                "newArtists": index.artists.map(\.name).filter { !names.contains($0) }.prefix(16).map { $0 },
                "multiDiscAlbums": multiDisc.prefix(8).map { album in
                    "\(album.title) | " + album.tracks.prefix(3).map { "\($0.discNumber)-\($0.trackNumber)" }.joined(separator: " ") + " … "
                        + album.tracks.suffix(2).map { "\($0.discNumber)-\($0.trackNumber)" }.joined(separator: " ")
                },
                "multiDiscCount": multiDisc.count
            ])
        }
    }

    private func measureRebuild() {
        let tracks = model.library.tracks
        let addedAt = model.library.addedAt
        let decisions = model.review.decisions
        var seen = Set<String>()
        let entries = (model.playlists.library + model.playlists.playlists.flatMap(\.entries)).filter { seen.insert($0.trackID).inserted }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = Date()
            let resolution = MatchResolver.resolve(tracks: tracks, entries: entries, decisions: decisions)
            let resolved = Date()
            let index = LibraryIndex.build(tracks: tracks, addedAt: addedAt, apple: resolution.apple, decisions: decisions)
            let indexed = Date()
            let cache = MatchSuggestionCache()
            cache.update(entries: entries, tracks: tracks)
            let first = cache.scores(for: index.unmatchedTracks)
            let scored = Date()
            cache.update(entries: entries, tracks: tracks)
            _ = cache.scores(for: index.unmatchedTracks)
            self?.reply(["resolve": resolved.timeIntervalSince(start),
                         "index": indexed.timeIntervalSince(resolved),
                         "suggestFirst": scored.timeIntervalSince(indexed),
                         "suggestRepeat": Date().timeIntervalSince(scored),
                         "scores": first.count])
        }
    }

    private func list(playlist index: Int, from start: Int, count: Int) -> [String: Any] {
        let playlist = model.playlists.playlists[index]
        let rows = playlist.entries.dropFirst(start).prefix(count).map { entry -> String in
            let match = model.match(for: entry)
            let local = match.map { "\($0.track.sampleRate)/\($0.track.bitsPerSample) \($0.confidence)" } ?? "-"
            return "\(entry.position) | \(entry.title) | \(Int(entry.duration))s | local=\(local) | \(entry.cloudStatus)"
        }
        return ["name": playlist.name, "rows": Array(rows)]
    }

    private func summary() -> [String: Any] {
        let index = model.index
        return [
            "tracks": model.library.tracks.count,
            "albums": index.albums.count,
            "artists": index.artists.count,
            "genres": index.genres.map { "\($0.name) \($0.albums.count)/\($0.trackCount)" },
            "composers": index.composers.count,
            "compilations": index.compilations.count,
            "recent": index.recent.count,
            "unmatchedTracks": index.unmatchedTracks.count,
            "unmatchedAlbums": index.unmatchedAlbums.count,
            "favoritesLocal": model.favoritePaths.count,
            "musicLibrary": model.playlists.library.count,
            "favoritesMusic": model.playlists.library.filter { $0.isFavorite == true }.count,
            "matches": model.matches.count,
            "unmatchedSample": index.unmatchedTracks.prefix(40).map { "\($0.title) | \($0.artist) | \($0.album)" }
        ]
    }

    private func state() -> [String: Any] {
        let player = model.player
        return [
            "status": "\(player.status)",
            "route": player.activeRoute?.rawValue ?? "",
            "index": player.currentIndex ?? -1,
            "queue": player.queue.count,
            "title": player.currentItem?.title ?? "",
            "elapsed": player.clock.elapsed,
            "duration": player.clock.duration,
            "path": player.outputPath?.rawValue ?? "",
            "format": player.sourceFormat?.description ?? "",
            "message": player.message ?? "",
            "verification": player.lastVerification.map { "\($0.title) passed=\($0.passed) file=\($0.matchedFile)" } ?? "",
            "exclusive": BitPerfectClient.isExclusive,
            "device": model.routing.currentUID.flatMap(OutputDeviceInfo.name(uid:)) ?? "",
            "playlists": model.playlists.playlists.count,
            "matches": model.matches.count,
            "stream": model.streamFormat.map { "\($0.sampleRate)/\($0.bitDepth)" } ?? "",
            "deviceName": model.outputDeviceName,
            "sync": "\(model.playlists.syncState)",
            "appearance": NSApp.effectiveAppearance.name.rawValue,
            "deviceVolume": model.deviceVolume.map(Double.init) ?? -1,
            "duplicates": model.duplicates.count,
            "sheets": NSApp.windows.compactMap(\.attachedSheet).map { NSStringFromSize($0.frame.size) },
            "selection": "\(model.navigation.selection.map(String.init(describing:)) ?? "nil")"
        ]
    }

    private func reply(_ object: [String: Any]) {
        guard let directory, let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("out"), options: .atomic)
    }
}
#endif
