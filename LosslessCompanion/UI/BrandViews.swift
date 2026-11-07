//
//  BrandViews.swift
//  LosslessCompanion
//
//  App 的標誌圖。關於頁和開啟時的啟動畫面共用，右下角印著製作者。
//

import AppKit
import SwiftUI

/// 標誌圖加上右下角的 Powered by。文字大小跟著圖片寬度縮放，放大縮小都在同一個位置
struct BrandBanner: View {
    /// 和標誌上的金色同一系
    static let ink = Color(red: 0.55, green: 0.44, blue: 0.27)

    var body: some View {
        if let image = NSImage(named: "BrandBanner") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .overlay(alignment: .bottomTrailing) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        Text(verbatim: "Powered by Talon and Claude")
                            .font(.system(size: max(7, width * 0.015), weight: .medium, design: .serif))
                            .tracking(width * 0.0012)
                            .foregroundStyle(Self.ink.opacity(0.85))
                            .padding(.trailing, width * 0.035)
                            .padding(.bottom, width * 0.028)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("LosslessCompanion 標誌，Powered by Talon and Claude")
        }
    }
}

/// 開啟 App 時先顯示標誌，一下子就淡出
struct LaunchSplash: View {
    /// 標誌底色，讓圖片邊緣和背景接起來
    private static let paper = Color(red: 0.95, green: 0.93, blue: 0.90)

    var body: some View {
        ZStack {
            Self.paper
            BrandBanner()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                .frame(maxWidth: 720)
                .padding(48)
        }
        .ignoresSafeArea()
    }
}
