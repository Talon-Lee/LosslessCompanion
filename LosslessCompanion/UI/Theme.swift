//
//  Theme.swift
//  LosslessCompanion
//
//  版面節奏以 Apple Music 為藍本：大標題、圓角封面、低對比的列表。
//  顏色只用帶一點暖調的中性色，畫面上的色彩留給專輯封面。
//

import AppKit
import SwiftUI

enum Theme {
    /// 主要按鈕與進度的填色，淺色模式近黑、深色模式近白
    static let accent = Color(nsColor: adaptive(light: 0x2A2A2C, dark: 0xECE9E3))
    /// 放在 accent 上的文字與圖示
    static let onAccent = Color(nsColor: adaptive(light: 0xF7F5F1, dark: 0x1B1B1D))

    static let artworkRadius: CGFloat = 8
    static let smallArtworkRadius: CGFloat = 4
    static let pagePadding: CGFloat = 32
    static let pageSpacing: CGFloat = 22
    static let coverSide: CGFloat = 220
    static let rowHeight: CGFloat = 50

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(isDark ? dark : light)
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension AppearanceMode {
    /// 設在 NSApp 上：側欄材質與對話框都會跟著變，nil 代表跟隨系統
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum Format {
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func longDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 {
            return String(localized: "\(minutes / 60) 小時 \(minutes % 60) 分鐘")
        }
        return String(localized: "\(minutes) 分鐘")
    }

    static func sampleRate(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
    }

    static func quality(rate: Double, bits: Int) -> String {
        "\(sampleRate(rate)) / \(bits)-bit"
    }

    /// 同一張專輯混用幾種取樣率時寫成 48/96 kHz
    static func sampleRates(_ rates: [Double]) -> String {
        let numbers = rates.sorted().map { rate -> String in
            let khz = rate / 1000
            return khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        }
        return numbers.joined(separator: "/") + " kHz"
    }

    static func isHiRes(rate: Double, bits: Int) -> Bool {
        rate > 48_000 || bits > 24
    }

    static func codec(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "flac": return "FLAC"
        case "aif", "aiff", "aifc": return "AIFF"
        case "m4a": return "ALAC"
        case "wav", "wave", "caf": return "PCM"
        default: return url.pathExtension.uppercased()
        }
    }

    static func deviceVolume(_ volume: Float?) -> String {
        volume.map { "\(Int(($0 * 100).rounded()))%" } ?? String(localized: "裝置沒有音量控制")
    }
}

/// 膠囊主要按鈕，頁面上最重的元素，對應 Apple Music 的「播放」
struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22)
            .frame(height: 32)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .frame(height: 32)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
    }
}

/// 歌曲的來源與規格標籤
struct QualityBadge: View {
    let rate: Double
    let bits: Int

    private var isHiRes: Bool { Format.isHiRes(rate: rate, bits: bits) }

    var body: some View {
        Text(isHiRes ? "Hi-Res" : "無損")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(isHiRes ? .primary : .secondary)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(isHiRes ? 0.42 : 0.2), lineWidth: 0.7)
            }
            .help(Format.quality(rate: rate, bits: bits))
    }
}

struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
    }
}

struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 30, weight: .bold))
    }
}

/// 頁面標題列：左邊標題，右邊是這一頁的控制項
struct PageHeader<Controls: View>: View {
    let title: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 16) {
            PageTitle(title: title)
            Spacer(minLength: 16)
            controls()
        }
    }
}

/// 專輯、歌單與歌手頁共用的頁首，三種頁面的節奏才會一致
struct DetailHeader<Cover: View, Details: View, Actions: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var details: () -> Details
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .bottom, spacing: 26) {
            cover()
                .shadow(color: .black.opacity(0.2), radius: 16, y: 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                details()
                // 待播清單打開時頁面變窄，按鈕排不下就換成兩行，不要把整個視窗撐開
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions() }
                    VStack(alignment: .leading, spacing: 8) { actions() }
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 12)
            // 比封面矮的內容要貼在頁首右上角，不是跟著按鈕排在底部
            accessory()
                .frame(height: Theme.coverSide, alignment: .top)
        }
    }
}

extension DetailHeader where Accessory == EmptyView {
    init(title: String, @ViewBuilder cover: @escaping () -> Cover, @ViewBuilder details: @escaping () -> Details,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, cover: cover, details: details, actions: actions) { EmptyView() }
    }
}

extension View {
    /// 頁面上的篩選與排序：不加外框，不和播放鍵搶視線
    func pageMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// 頁面選單的文字，和其他次要控制項同一個大小
struct PageMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// 頁首按鈕列最後的 ⋯
struct MoreMenu<Items: View>: View {
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("更多動作")
    }
}
