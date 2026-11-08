//
//  AppSettings.swift
//  LosslessCompanion
//

import Combine
import Foundation

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LosslessCompanionHog")
    static let legacyArtworkCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LosslessCompanionHog/Artwork")
    static let artworkCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LosslessCompanionHog/Artwork-v2")
    static let losslessSwitcherLibraryCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LosslessSwitcher/library-v1.json")
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "跟隨系統")
        case .light: return String(localized: "淺色")
        case .dark: return String(localized: "深色")
        }
    }
}

/// 介面語言。macOS「語言與地區」裡的 App 語言也是這個設定，只在啟動時讀取，改了要重新開啟 App
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    /// macOS 寫入的值可能帶地區，例如 zh-Hant-TW
    init(code: String?) {
        self = Self.allCases.first { $0 != .system && code?.hasPrefix($0.rawValue) == true } ?? .system
    }

    var title: String {
        switch self {
        case .system: return String(localized: "跟隨系統")
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let libraryFolders = "libraryFolders"
        static let deviceUID = "deviceUID"
        static let defaultPreference = "defaultPreference"
        static let playlistPreferences = "playlistPreferences"
        static let trackSorts = "trackSorts"
        static let albumSort = "albumSort"
        static let appearance = "appearance"
        static let languages = "AppleLanguages"
        static let keepsRunningInBackground = "keepsRunningInBackground"
        static let outputOptions = "outputOptions"
        static let verifiesStreamSamples = "verifiesStreamSamples"
        static let usesHogBridge = "usesHogBridge"
        static let processesInbox = "processesInbox"
    }

    private let defaults = UserDefaults.standard

    @Published var libraryFolders: [String] {
        didSet { defaults.set(libraryFolders, forKey: Key.libraryFolders) }
    }

    /// nil 代表跟隨系統預設輸出
    @Published var deviceUID: String? {
        didSet { defaults.set(deviceUID, forKey: Key.deviceUID) }
    }

    @Published var defaultPreference: RoutePreference {
        didSet { defaults.set(defaultPreference.rawValue, forKey: Key.defaultPreference) }
    }

    @Published private var playlistPreferences: [String: String] {
        didSet { defaults.set(playlistPreferences, forKey: Key.playlistPreferences) }
    }

    @Published private var trackSorts: [String: String] {
        didSet { defaults.set(trackSorts, forKey: Key.trackSorts) }
    }

    @Published var albumSort: AlbumSortKey {
        didSet { defaults.set(albumSort.rawValue, forKey: Key.albumSort) }
    }

    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var language: AppLanguage {
        didSet {
            if language == .system { defaults.removeObject(forKey: Key.languages) }
            else { defaults.set([language.rawValue], forKey: Key.languages) }
        }
    }

    /// 這次啟動實際使用的語言，和 language 不同時介面還沒換過去
    let launchLanguage: AppLanguage

    /// 關掉視窗後仍切換串流取樣率，和 Apple Music 一樣留在背景
    @Published var keepsRunningInBackground: Bool {
        didSet { defaults.set(keepsRunningInBackground, forKey: Key.keepsRunningInBackground) }
    }

    /// 需要系統音訊錄音權限，所以預設關閉
    @Published var verifiesStreamSamples: Bool {
        didSet { defaults.set(verifiesStreamSamples, forKey: Key.verifiesStreamSamples) }
    }

    /// Hog 模式：Apple Music 輸出到 LosslessCompanion Bridge，由本 App 獨佔 DAC 轉送。需要安裝 Bridge 驅動
    @Published var usesHogBridge: Bool {
        didSet { defaults.set(usesHogBridge, forKey: Key.usesHogBridge) }
    }

    /// 收件匣：放進去的歌自動轉成 FLAC、依 Apple Music 補標籤並分類
    @Published var processesInbox: Bool {
        didSet { defaults.set(processesInbox, forKey: Key.processesInbox) }
    }

    /// 以裝置 UID 為索引，每台 DAC 的鎖定時間不同
    @Published private var deviceOutputOptions: [String: OutputOptions] {
        didSet { defaults.set(try? JSONEncoder().encode(deviceOutputOptions), forKey: Key.outputOptions) }
    }

    private init() {
        if let folders = defaults.stringArray(forKey: Key.libraryFolders), !folders.isEmpty {
            libraryFolders = folders
        }
        else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let hiRes = home.appendingPathComponent("Documents/HI-RES").path
            libraryFolders = [FileManager.default.fileExists(atPath: hiRes) ? hiRes : home.appendingPathComponent("Music").path]
        }
        deviceUID = defaults.string(forKey: Key.deviceUID)
        defaultPreference = defaults.string(forKey: Key.defaultPreference).flatMap(RoutePreference.init(rawValue:)) ?? .preferLocal
        playlistPreferences = defaults.dictionary(forKey: Key.playlistPreferences) as? [String: String] ?? [:]
        trackSorts = defaults.dictionary(forKey: Key.trackSorts) as? [String: String] ?? [:]
        albumSort = defaults.string(forKey: Key.albumSort).flatMap(AlbumSortKey.init(rawValue:)) ?? .title
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        // 沒有設定時 defaults 會傳回系統的語言清單，要只看 App 自己的
        let languages = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Key.languages] as? [String]
        launchLanguage = AppLanguage(code: languages?.first)
        language = launchLanguage
        keepsRunningInBackground = defaults.object(forKey: Key.keepsRunningInBackground) as? Bool ?? true
        verifiesStreamSamples = defaults.bool(forKey: Key.verifiesStreamSamples)
        usesHogBridge = defaults.object(forKey: Key.usesHogBridge) as? Bool ?? true
        processesInbox = defaults.object(forKey: Key.processesInbox) as? Bool ?? true
        #if DEBUG
        if ProcessInfo.processInfo.environment["LC_STREAM_VERIFY"] != nil { verifiesStreamSamples = true }
        #endif
        deviceOutputOptions = defaults.data(forKey: Key.outputOptions)
            .flatMap { try? JSONDecoder().decode([String: OutputOptions].self, from: $0) } ?? [:]
    }

    var outputOptionsChanged: AnyPublisher<Void, Never> {
        $deviceOutputOptions.map { _ in () }.eraseToAnyPublisher()
    }

    func outputOptions(for deviceUID: String) -> OutputOptions {
        deviceOutputOptions[deviceUID] ?? OutputOptions()
    }

    func setOutputOptions(_ options: OutputOptions, for deviceUID: String) {
        deviceOutputOptions[deviceUID] = options
    }

    func preference(for playlistID: String) -> RoutePreference {
        playlistPreferences[playlistID].flatMap(RoutePreference.init(rawValue:)) ?? defaultPreference
    }

    func setPreference(_ preference: RoutePreference, for playlistID: String) {
        playlistPreferences[playlistID] = preference.rawValue
    }

    /// key 是歌單 ID，或本地清單的固定名稱
    func trackSort(for key: String) -> TrackSort {
        trackSorts[key].flatMap(TrackSort.init(storage:)) ?? .original
    }

    func setTrackSort(_ sort: TrackSort, for key: String) {
        trackSorts[key] = sort.storage
    }
}
