//
//  Artwork.swift
//  LosslessCompanion
//
//  封面在背景讀取並縮圖，存在記憶體與磁碟快取；捲動清單時不解碼大圖。
//  本地封面取自檔案，Apple Music 的封面向 Music 要，一次只問一張。
//

import AppKit
import CryptoKit
import ImageIO
import SwiftUI

enum ArtworkSource: Hashable {
    case local(LibraryTrack)
    case stream(StreamReference)
    /// 不是每個本地檔案都有封面，沒有時改向 Music 要
    case localThenStream(LibraryTrack, StreamReference)
    /// Music 資料庫裡不一定在任何歌單中的歌曲
    case musicLibrary(trackID: String)
    case none

    /// 同一張專輯共用一張圖；同一個資料夾可能混放不同專輯，所以連專輯名稱一起算
    fileprivate var cacheKey: String? {
        switch self {
        case .local(let track), .localThenStream(let track, _): return "local:\(track.folder)\n\(track.album)"
        case .stream(let reference): return "stream:" + reference.trackID
        case .musicLibrary(let trackID): return "stream:" + trackID
        case .none: return nil
        }
    }
}

struct ArtworkRequest: Hashable {
    let source: ArtworkSource
    let generation: Int
}

extension QueueItem {
    var artworkSource: ArtworkSource {
        switch (local, stream) {
        case (let local?, let stream?): return .localThenStream(local, stream)
        case (let local?, nil): return .local(local)
        case (nil, let stream?): return .stream(stream)
        case (nil, nil): return .none
        }
    }
}

final class ArtworkStore: ObservableObject {
    static let shared = ArtworkStore()

    /// 清除快取後遞增，畫面上的封面才會重新讀取
    @Published private(set) var generation = 0

    private let memory = NSCache<NSString, NSImage>()
    /// 確定找不到封面的本地專輯，捲動時不必一直重新翻檔案
    private let absent = NSCache<NSString, NSNumber>()
    private let diskQueue = DispatchQueue(label: "ArtworkStore.disk", qos: .userInitiated, attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 4)
    private let fileManager = FileManager.default

    /// 磁碟只存一種尺寸，顯示時由系統縮放
    private static let storedSide: CGFloat = 600

    init() {
        memory.countLimit = 600
        try? fileManager.removeItem(at: AppPaths.legacyArtworkCache)
        try? fileManager.createDirectory(at: AppPaths.artworkCache, withIntermediateDirectories: true)
    }

    func image(for source: ArtworkSource, side: CGFloat) async -> NSImage? {
        guard let key = source.cacheKey else { return nil }
        let memoryKey = "\(key)#\(Int(side))" as NSString
        if let cached = memory.object(forKey: memoryKey) { return cached }
        if absent.object(forKey: key as NSString) != nil { return nil }

        let file = cacheFile(for: key)
        let stored = await read(file)
        let data: Data?
        if let stored {
            data = stored
        }
        else {
            data = await fetch(source)
            if let data { await write(data, to: file) }
            else if case .local = source { absent.setObject(true, forKey: key as NSString) }
        }
        guard let data, let image = Self.thumbnail(from: data, side: side) else { return nil }
        memory.setObject(image, forKey: memoryKey)
        return image
    }

    /// 換過檔案裡的封面後，已快取的圖不會自己更新
    func clearCache() {
        memory.removeAllObjects()
        absent.removeAllObjects()
        let fileManager = self.fileManager
        diskQueue.async(flags: .barrier) { [weak self] in
            try? fileManager.removeItem(at: AppPaths.artworkCache)
            try? fileManager.createDirectory(at: AppPaths.artworkCache, withIntermediateDirectories: true)
            DispatchQueue.main.async { self?.generation += 1 }
        }
    }

    private func fetch(_ source: ArtworkSource) async -> Data? {
        switch source {
        case .local(let track):
            return await withCheckedContinuation { continuation in
                diskQueue.async { [limiter] in
                    limiter.wait()
                    defer { limiter.signal() }
                    let data = TrackArtwork.data(for: track).flatMap { Self.stored(from: $0) }
                    continuation.resume(returning: data)
                }
            }
        case .stream(let reference):
            return await readFromMusic(try? MusicScripts.artwork(playlistID: reference.playlistID, trackID: reference.trackID))
        case .localThenStream(let track, let reference):
            if let data = await fetch(.local(track)) { return data }
            return await fetch(.stream(reference))
        case .musicLibrary(let trackID):
            return await readFromMusic(try? MusicScripts.libraryArtwork(trackID: trackID))
        case .none:
            return nil
        }
    }

    private func readFromMusic(_ script: String?) async -> Data? {
        guard AppRuntime.current.canReadMusic, MusicScriptRunner.shared.isMusicRunning, let script else { return nil }
        return await withCheckedContinuation { continuation in
            MusicScriptRunner.shared.run(script) { result in
                let data = (try? result.get())?.data
                continuation.resume(returning: data.flatMap { Self.stored(from: $0) })
            }
        }
    }

    private func read(_ file: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            diskQueue.async { continuation.resume(returning: try? Data(contentsOf: file)) }
        }
    }

    private func write(_ data: Data, to file: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            diskQueue.async {
                try? data.write(to: file, options: .atomic)
                continuation.resume()
            }
        }
    }

    private func cacheFile(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return AppPaths.artworkCache.appendingPathComponent(digest + ".jpg")
    }

    /// 重新編碼成固定大小的 JPEG，內嵌的大圖不必每次重新解碼
    private static func stored(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = centerCropped(source, side: storedSide) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    }

    private static func thumbnail(from data: Data, side: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = centerCropped(source, side: side * 2) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }

    private static func centerCropped(_ source: CGImageSource, side: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(image.width, image.height)
        return image.cropping(to: CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge))
    }
}

struct ArtworkView: View {
    let source: ArtworkSource
    let side: CGFloat
    var radius: CGFloat = Theme.smallArtworkRadius
    var showsPlaceholder = true

    @ObservedObject private var store = ArtworkStore.shared
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            }
            else if showsPlaceholder {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.34, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if showsPlaceholder {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .task(id: ArtworkRequest(source: source, generation: store.generation)) {
            image = await store.image(for: source, side: side)
        }
    }
}

/// 播放列表封面：取前四張不同的封面拼成一張
struct PlaylistCover: View {
    let sources: [ArtworkSource]
    let side: CGFloat

    var body: some View {
        Group {
            if sources.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(0)
                        tile(1)
                    }
                    HStack(spacing: 0) {
                        tile(2)
                        tile(3)
                    }
                }
            }
            else {
                ArtworkView(source: sources.first ?? .none, side: side, radius: 0)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func tile(_ index: Int) -> some View {
        ArtworkView(source: sources[index], side: side / 2, radius: 0)
    }
}

extension AppModel {
    /// 優先用本地封面，取得快又不必詢問 Music
    func coverSources(for playlist: MusicPlaylist, limit: Int = 4) -> [ArtworkSource] {
        let localFirst = playlist.entries.filter { match(for: $0) != nil } + playlist.entries.filter { match(for: $0) == nil }
        var seenAlbums = Set<String>()
        var sources = [ArtworkSource]()
        for entry in localFirst {
            guard seenAlbums.insert(TrackMatcher.albumKey(entry.album)).inserted else { continue }
            sources.append(artworkSource(for: entry, in: playlist))
            if sources.count == limit { break }
        }
        return sources
    }

    func artworkSource(for entry: MusicPlaylistEntry, in playlist: MusicPlaylist) -> ArtworkSource {
        let reference = StreamReference(playlistID: playlist.id, trackID: entry.trackID)
        if let track = match(for: entry)?.track { return .localThenStream(track, reference) }
        return .stream(reference)
    }
}
