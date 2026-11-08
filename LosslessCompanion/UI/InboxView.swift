//
//  InboxView.swift
//  LosslessCompanion
//

import AppKit
import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var inbox: InboxModel
    @EnvironmentObject private var settings: AppSettings
    @State private var editing: InboxModel.Item?

    private var attention: [InboxModel.Item] {
        inbox.items.filter {
            switch $0.status {
            case .review, .failed: return true
            default: return false
            }
        }
    }

    private var working: [InboxModel.Item] {
        inbox.items.filter {
            switch $0.status {
            case .waiting, .working: return true
            default: return false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageSpacing) {
                PageHeader(title: String(localized: "收件匣")) {
                    Toggle("自動處理", isOn: $settings.processesInbox)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                    Button {
                        if let folder = inbox.folder, inbox.ensureFolder() { NSWorkspace.shared.open(folder) }
                    } label: {
                        Label("在 Finder 中打開", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryPillStyle())
                    .fixedSize()
                    Button {
                        inbox.processNow()
                    } label: {
                        Label("立即處理", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    .disabled(inbox.isWorking)
                }

                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !working.isEmpty {
                    SectionHeading(title: String(localized: "處理中"))
                    VStack(spacing: 0) {
                        ForEach(working) { item in
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(item.name).lineLimit(1)
                                Spacer()
                                if case .working(let step) = item.status {
                                    Text(step).foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: 12.5))
                            .padding(.vertical, 6)
                        }
                    }
                }

                SectionHeading(title: String(localized: "需要確認"))
                if attention.isEmpty {
                    Text("沒有需要確認的歌。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                else {
                    VStack(spacing: 12) {
                        ForEach(attention) { item in
                            InboxReviewCard(item: item, onEdit: { editing = item })
                        }
                    }
                }

                if !inbox.log.isEmpty {
                    SectionHeading(title: String(localized: "最近歸檔"))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(inbox.log.prefix(40)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(entry.date, style: .relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                Text(entry.destination).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if let note = entry.note {
                                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                    Text("要復原歸檔，到「設定 › 檔案整理紀錄」。復原後歌會回到收件匣，等你確認。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { item in
            InboxEditSheet(item: item)
        }
    }

    private var summary: String {
        let path = inbox.folder?.path ?? String(localized: "（請先在設定加入本地音樂資料夾）")
        return String(localized: "把歌放進 \(path)。ALAC 的 m4a 會轉成 FLAC，逐樣本比對一致後原檔移到垃圾桶；標籤以 Music 資料庫或 Apple Music 目錄為準；再依現有的歌手資料夾或類型放進對應的類別。有把握的直接歸檔，其餘列在這裡。")
    }
}

private struct InboxReviewCard: View {
    @EnvironmentObject private var inbox: InboxModel
    let item: InboxModel.Item
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.plan?.metadata.title.isEmpty == false ? item.plan!.metadata.title : item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let plan = item.plan {
                    Text(plan.metadata.folderArtist).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(item.name).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            if case .failed(let reason) = item.status {
                Label(reason, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let plan = item.plan {
                ForEach(plan.concerns, id: \.self) { concern in
                    Label(concern, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text("標籤來源：\(plan.source.label)").foregroundStyle(.secondary)
                Text("放到：\(plan.relativeDestination)").foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            if let note = item.note {
                Text(note).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let plan = item.plan, plan.category != nil {
                    Button("確認歸檔") { inbox.confirm(item, plan: plan) }
                        .buttonStyle(PrimaryPillStyle())
                }
                if item.plan != nil {
                    Button("修改…", action: onEdit).buttonStyle(SecondaryPillStyle())
                }
                Button("重新比對") { inbox.retry(item) }.buttonStyle(SecondaryPillStyle())
                Button("在 Finder 中顯示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
                .buttonStyle(SecondaryPillStyle())
            }
            .disabled(inbox.isWorking)
            .padding(.top, 4)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct InboxEditSheet: View {
    @EnvironmentObject private var inbox: InboxModel
    @Environment(\.dismiss) private var dismiss
    let item: InboxModel.Item

    @State private var metadata = InboxMetadata()
    @State private var category = ""
    @State private var layout: InboxLayout?

    private var plan: InboxPlan? {
        guard let original = item.plan, let layout else { return nil }
        return InboxPlanner.replan(original, metadata: metadata, category: category.isEmpty ? nil : category,
                                   fileExtension: item.fileExtension, layout: layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改後歸檔").font(.system(size: 17, weight: .bold))
            Form {
                TextField("歌名", text: $metadata.title)
                TextField("歌手", text: $metadata.artist)
                TextField("專輯歌手", text: $metadata.albumArtist)
                TextField("專輯", text: $metadata.album)
                TextField("音軌", value: $metadata.trackNumber, format: .number.grouping(.never))
                TextField("碟號", value: $metadata.discNumber, format: .number.grouping(.never))
                TextField("年份", value: $metadata.year, format: .number.grouping(.never))
                TextField("類型", text: $metadata.genre)
                Picker("類別", selection: $category) {
                    Text("自動判斷").tag("")
                    ForEach(layout?.categories ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
            if let plan {
                Text("放到：\(plan.relativeDestination)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                ForEach(plan.concerns.filter { $0 != String(localized: "Apple Music 找不到這首歌，標籤來自檔案本身") }, id: \.self) { concern in
                    Label(concern, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("歸檔") {
                    if var plan {
                        // 使用者看過並確認了，標籤來源與猜測類別的疑慮不再擋住
                        plan.concerns = []
                        inbox.confirm(item, plan: plan)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.category == nil || metadata.title.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            metadata = item.plan?.metadata ?? InboxMetadata()
            category = item.plan?.category ?? ""
            layout = inbox.layout()
        }
    }
}
