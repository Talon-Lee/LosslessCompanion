//
//  MusicScripts.swift
//  LosslessCompanion
//
//  和 Music 溝通的 AppleScript。NSAppleScript 不能同時在多條執行緒使用，全部排進同一個序列佇列；
//  Music 忙碌時腳本會等好幾秒，所以不能在主執行緒執行。大量讀取放到獨立程序，不會擋住播放指令。
//

import AppKit
import Foundation

enum MusicScriptError: LocalizedError, Equatable {
    case notAuthorized
    case notRunning
    case invalidIdentifier
    case failed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "尚未允許控制 Apple Music。請到 系統設定 › 隱私權與安全性 › 自動化 開啟。")
        case .notRunning:
            return String(localized: "Apple Music 沒有開啟。")
        case .invalidIdentifier:
            return String(localized: "歌曲識別碼不正確。")
        case .failed(_, let message):
            return String(localized: "Apple Music 回報錯誤：\(message)")
        }
    }
}

final class MusicScriptRunner {
    static let shared = MusicScriptRunner()

    private let queue = DispatchQueue(label: "MusicScriptRunner", qos: .userInitiated)

    private static let notAuthorizedCode = -1743
    private static let notRunningCodes = [-600, -609]

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    func run(_ source: String, completion: @escaping (Result<NSAppleEventDescriptor, MusicScriptError>) -> Void) {
        queue.async {
            var failure: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&failure)
            let outcome: Result<NSAppleEventDescriptor, MusicScriptError>
            if let result, failure == nil {
                outcome = .success(result)
            }
            else {
                outcome = .failure(Self.error(from: failure))
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// 回呼在背景執行緒。App 從 Finder 啟動時沒有語系環境變數，要指定才不會弄壞非 ASCII 文字
    func runInSubprocess(_ source: String, completion: @escaping (Result<String, MusicScriptError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            process.environment = ProcessInfo.processInfo.environment.merging(["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]) { _, new in new }
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            }
            catch {
                completion(.failure(.failed(0, error.localizedDescription)))
                return
            }
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
            // 輸出可能比管線緩衝大，要先讀完才等程序結束
            let result = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                completion(.success(String(decoding: result, as: UTF8.self)))
            }
            else if message.contains("\(Self.notAuthorizedCode)") {
                completion(.failure(.notAuthorized))
            }
            else {
                completion(.failure(.failed(Int(process.terminationStatus), message.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
        }
    }

    private static func error(from dictionary: NSDictionary?) -> MusicScriptError {
        let code = dictionary?[NSAppleScript.errorNumber] as? Int ?? 0
        if code == notAuthorizedCode { return .notAuthorized }
        if notRunningCodes.contains(code) { return .notRunning }
        return .failed(code, dictionary?[NSAppleScript.errorMessage] as? String ?? String(localized: "未知錯誤"))
    }
}

enum MusicScripts {
    /// 一次取回整欄資料，比逐首讀取快得多。資料庫放在最後，只有它讀取加入日期：
    /// 日期要在腳本裡逐筆換算，歌單再讀一次只會變慢
    static let readLibrary = #"""
    on joined(values, separator)
        set saved to AppleScript's text item delimiters
        set AppleScript's text item delimiters to separator
        set merged to values as text
        set AppleScript's text item delimiters to saved
        return merged
    end joined

    on secondsFrom(dateList, baseDate)
        set offsets to {}
        repeat with d in dateList
            set end of offsets to ((contents of d) - baseDate)
        end repeat
        return offsets
    end secondsFrom

    on describe(p, isSmart, kindName, baseDate)
        set us to character id 31
        tell application "Music"
            set n to count of tracks of p
            set parts to {my joined({persistent ID of p, name of p, isSmart as text, kindName, n as text}, us)}
            if n > 0 then
                set columns to {persistent ID, name, artist, album artist, album, duration, track number, disc number, year, cloud status, genre, composer, favorited} of tracks of p
                repeat with c in columns
                    set end of parts to my joined(contents of c, us)
                end repeat
                if kindName is "library" then
                    set addedDates to date added of tracks of p
                    set end of parts to my joined(my secondsFrom(addedDates, baseDate), us)
                end if
            end if
        end tell
        return my joined(parts, character id 30)
    end describe

    set baseDate to current date
    set groups to {}
    tell application "Music"
        repeat with p in (every user playlist whose special kind is none)
            set end of groups to my describe(p, smart of p, "user", baseDate)
        end repeat
        repeat with p in (every subscription playlist)
            set end of groups to my describe(p, false, "subscription", baseDate)
        end repeat
        set end of groups to my describe(library playlist 1, false, "library", baseDate)
    end tell
    return my joined(groups, character id 29)
    """#

    /// Music 資料庫裡的本機檔案，一行一個路徑。檔案已經找不到的歌曲讀位置會出錯，略過
    static let fileTrackLocations = #"""
    set paths to {}
    tell application "Music"
        repeat with t in (file tracks of library playlist 1)
            try
                set end of paths to POSIX path of (location of t as alias)
            end try
        end repeat
    end tell
    set AppleScript's text item delimiters to linefeed
    return paths as text
    """#

    /// 代表整個資料庫。真正的 persistent ID 是 16 位數，不會和這個值相同
    static let libraryPlaylistID = "0"

    private static func playlistReference(_ id: String) -> String {
        id == libraryPlaylistID ? "library playlist 1" : "(first playlist whose persistent ID is \"\(id)\")"
    }

    static func play(playlistID: String, trackID: String) throws -> String {
        guard isIdentifier(playlistID), isIdentifier(trackID) else { throw MusicScriptError.invalidIdentifier }
        return """
        tell application "Music"
            set theTrack to first track of \(playlistReference(playlistID)) whose persistent ID is "\(trackID)"
            play theTrack
        end tell
        """
    }

    static func artwork(playlistID: String, trackID: String) throws -> String {
        guard isIdentifier(playlistID), isIdentifier(trackID) else { throw MusicScriptError.invalidIdentifier }
        return """
        tell application "Music"
            return raw data of artwork 1 of (first track of \(playlistReference(playlistID)) whose persistent ID is "\(trackID)")
        end tell
        """
    }

    static func libraryArtwork(trackID: String) throws -> String {
        guard isIdentifier(trackID) else { throw MusicScriptError.invalidIdentifier }
        return """
        tell application "Music"
            return raw data of artwork 1 of (first track of library playlist 1 whose persistent ID is "\(trackID)")
        end tell
        """
    }

    static func seek(to seconds: TimeInterval) -> String {
        "tell application \"Music\" to set player position to \(String(format: "%.3f", max(0, seconds)))"
    }

    static func setVolume(_ volume: Int) -> String {
        "tell application \"Music\" to set sound volume to \(max(0, min(100, volume)))"
    }

    static let resume = "tell application \"Music\" to play"
    static let isPlaying = "tell application \"Music\" to get player state is playing"
    static let playerPosition = "tell application \"Music\" to get player position"
    /// 只看通知不夠：自動播放接上的歌曲，通知裡沒有 PersistentID
    static let playerProgress = "tell application \"Music\" to get {player position, persistent ID of current track}"
    static let volume = "tell application \"Music\" to get sound volume"
    /// 沒有目前歌曲時單曲欄位讀不到，要分開處理
    static let processing = """
    tell application "Music"
        set adjustment to 0
        set trackEQ to ""
        try
            set adjustment to volume adjustment of current track
            set trackEQ to EQ of current track
        end try
        return {sound volume, mute, EQ enabled, AirPlay enabled, adjustment, trackEQ}
    end tell
    """

    /// 識別碼會嵌進腳本，只接受 Music 使用的十六進位字串
    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 16 && text.allSatisfy(\.isHexDigit)
    }

    /// 通知裡的 PersistentID 是有號整數，腳本用的是 16 位十六進位字串
    static func hexIdentifier(from number: NSNumber) -> String {
        String(format: "%016llX", UInt64(bitPattern: number.int64Value))
    }
}
