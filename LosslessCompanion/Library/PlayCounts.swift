//
//  PlayCounts.swift
//  LosslessCompanion
//
//  本地檔案的播放次數。存在本機，不寫進音檔：
//  改檔案會讓每次播放都改動修改時間，也會影響最近加入的排序。
//

import Combine
import Foundation

struct PlayRecord: Codable, Equatable {
    var count: Int
    var lastPlayed: Date
}

final class PlayCountStore: ObservableObject {
    @Published private(set) var records = [String: PlayRecord]() {
        didSet { save() }
    }

    private let fileURL: URL

    init(directory: URL = AppPaths.support) {
        fileURL = directory.appendingPathComponent("play-counts-v1.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: PlayRecord].self, from: data) {
            records = saved
        }
    }

    func count(for path: String) -> Int {
        records[path]?.count ?? 0
    }

    func recordPlay(of path: String, at date: Date = Date()) {
        records[path] = PlayRecord(count: count(for: path) + 1, lastPlayed: date)
    }

    func apply(_ moves: [FileMove]) {
        var updated = records
        for move in moves {
            if let record = updated.removeValue(forKey: move.from) { updated[move.to] = record }
        }
        if updated != records { records = updated }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
