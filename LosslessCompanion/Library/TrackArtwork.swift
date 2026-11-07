//
//  TrackArtwork.swift
//  LosslessCompanion
//
//  找出一首歌的封面：先看檔案本身，再看資料夾裡的圖檔，最後向同一張專輯的其他檔案借。
//  只讀中繼資料，不解碼音訊。
//

import Foundation

enum TrackArtwork {
    private static let preferredNames = ["cover", "folder", "front", "album"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func data(for track: LibraryTrack) -> Data? {
        let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: track.folder),
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return embedded(in: track.url) ?? folderImage(in: files) ?? borrowedPicture(for: track, files: files)
    }

    static func embedded(in url: URL) -> Data? {
        switch url.pathExtension.lowercased() {
        case "flac": return FLACBlocks.read(url: url, includePicture: true).picture
        case "wav", "wave", "aif", "aiff", "aifc": return AudioChunks.id3Tag(in: url).flatMap(ID3Tag.picture)
        case "m4a": return MP4Atoms.coverArt(in: url)
        default: return nil
        }
    }

    private static func folderImage(in files: [URL]) -> Data? {
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        let preferred = images.first { url in
            preferredNames.contains(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        return (preferred ?? images.first).flatMap { try? Data(contentsOf: $0) }
    }

    /// 有些專輯只有部分檔案內嵌封面。專輯標籤要相同，資料夾混放不同專輯時才不會借錯
    private static func borrowedPicture(for track: LibraryTrack, files: [URL]) -> Data? {
        let siblings = files
            .filter { LibraryInspector.candidateExtensions.contains($0.pathExtension.lowercased()) && $0.path != track.path }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for file in siblings where TrackMetadata.tags(for: file).album == track.album {
            if let picture = embedded(in: file) { return picture }
        }
        return nil
    }
}

/// M4A 的封面在 moov/udta/meta/ilst/covr/data
enum MP4Atoms {
    private static let atomHeaderLength: UInt64 = 8
    private static let largeAtomHeaderLength: UInt64 = 16
    private static let metaPrefixLength: UInt64 = 4
    private static let dataPrefixLength: UInt64 = 8

    static func coverArt(in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }

        guard let moov = child("moov", of: 0..<end, in: handle),
              let udta = child("udta", of: moov, in: handle),
              let meta = child("meta", of: udta, in: handle),
              let ilst = child("ilst", of: (meta.lowerBound + metaPrefixLength)..<meta.upperBound, in: handle),
              let covr = child("covr", of: ilst, in: handle),
              let data = child("data", of: covr, in: handle),
              data.upperBound > data.lowerBound + dataPrefixLength,
              (try? handle.seek(toOffset: data.lowerBound + dataPrefixLength)) != nil else { return nil }
        return try? handle.read(upToCount: Int(data.upperBound - data.lowerBound - dataPrefixLength))
    }

    private static func child(_ name: String, of parent: Range<UInt64>, in handle: FileHandle) -> Range<UInt64>? {
        var offset = parent.lowerBound
        while offset + atomHeaderLength <= parent.upperBound {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: Int(atomHeaderLength)), header.count == Int(atomHeaderLength) else { return nil }
            var size = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var headerLength = atomHeaderLength
            if size == 1 {
                guard let large = try? handle.read(upToCount: Int(atomHeaderLength)), large.count == Int(atomHeaderLength) else { return nil }
                size = large.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerLength = largeAtomHeaderLength
            }
            else if size == 0 {
                size = parent.upperBound - offset
            }
            guard size >= headerLength, offset + size <= parent.upperBound else { return nil }
            if String(decoding: header.dropFirst(4), as: UTF8.self) == name {
                return (offset + headerLength)..<(offset + size)
            }
            offset += size
        }
        return nil
    }
}
