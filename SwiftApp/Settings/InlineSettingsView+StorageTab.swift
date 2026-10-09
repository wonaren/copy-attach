import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 🟡 STORAGE TAB

extension InlineSettingsView {
    private var textPct: CGFloat {
        let threshold = CGFloat(max(Int(cleanupThreshold), 1))
        return CGFloat(textCount) / threshold
    }
    private var imagePct: CGFloat {
        let threshold = CGFloat(max(Int(cleanupThreshold), 1))
        return CGFloat(imageCount) / threshold
    }

    var storageTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                storageStatsCard
                backupRestoreCard
                cleanupCard
            }
            .padding(20)
        }
    }

    private var storageStatsCard: some View {
        settingsCard {
            HStack(spacing: 10) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 16))
                    .foregroundColor(Color.accentColor)
                Text("存储统计")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("(\(backend.items.count) / \(Int(cleanupThreshold)))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(.bottom, 12)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.cardBorder)
                                .frame(height: 12)
                            HStack(spacing: 0) {
                                Color.accentColor
                                    .frame(width: w * textPct)
                                Color(nsColor: .systemGreen)
                                    .frame(width: w * imagePct)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 12)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .animation(AppleMotion.smooth, value: textPct)
                            .animation(AppleMotion.smooth, value: imagePct)
                        }
                    }
                    .frame(height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
                    HStack(spacing: 16) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            Text("文本项目 (\(textCount))")
                                .font(.system(size: 10)).foregroundColor(theme.secondaryText)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(Color(nsColor: .systemGreen)).frame(width: 8, height: 8)
                            Text("图片项目 (\(imageCount))")
                                .font(.system(size: 10)).foregroundColor(theme.secondaryText)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("已使用存储空间")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Text(formatStorageSize(backend.getStorageSize()))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text("共 \(backend.items.count) 个剪贴板历史项目")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                .frame(width: 140)
                .padding(.leading, 16)
                .overlay(
                    Rectangle()
                        .fill(theme.divider)
                        .frame(width: 1),
                    alignment: .leading
                )
            }
        }
    }

    private var cleanupCard: some View {
        settingsCard {
            cardTitle(icon: "trash", text: "清理与维护")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("自动清理阈值")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Text("\(Int(cleanupThreshold)) 条")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
                Slider(value: $cleanupThreshold, in: 100...10000, step: 100) {
                    Text("")
                } onEditingChanged: { editing in
                    if editing {
                        thresholdBeforeEdit = cleanupThreshold
                    } else if Int(cleanupThreshold) < backend.items.count {
                        pendingThreshold = Int(cleanupThreshold)
                        cleanupThreshold = thresholdBeforeEdit
                    } else {
                        backend.setCleanupThreshold(Int(cleanupThreshold))
                    }
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    let minV: Double = 100
                    let maxV: Double = 10000
                    let range = maxV - minV
                    let ticks: [(String, Double)] = [
                        ("100", 100), ("500", 500), ("1k", 1000), ("1.5k", 1500),
                        ("2k", 2000), ("3k", 3000), ("5k", 5000), ("10k", 10000)
                    ]
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.0) { label, value in
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundColor(
                                    abs(cleanupThreshold - value) < 50
                                    ? Color.accentColor : theme.tertiaryText
                                )
                                .onTapGesture {
                                    let newVal = Int(value)
                                    if newVal < backend.items.count {
                                        thresholdBeforeEdit = cleanupThreshold
                                        pendingThreshold = newVal
                                    } else {
                                        cleanupThreshold = value
                                        backend.setCleanupThreshold(newVal)
                                    }
                                }
                                .position(x: w * (value - minV) / range, y: 4)
                        }
                    }
                }
                .frame(height: 14)
            }
            Text("当历史项目超过该阈值时，自动清理最早记录，以保护磁盘存储。")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .padding(.top, 4)

            sectionDivider().padding(.vertical, 4)

            HStack(spacing: 12) {
                Button {
                    let total = backend.items.count
                    guard total > 0 else { return }
                    let favorites = backend.favoriteIds
                    let cleanableCount = backend.items.filter { !favorites.contains($0.id) }.count
                    if cleanableCount == 0 {
                        let alert = NSAlert()
                        alert.messageText = "无需清理"
                        alert.informativeText = "当前所有剪贴板记录均已收藏，收藏的条目不会被清理。"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "好")
                        alert.runModal()
                        return
                    }
                    let estimated = Int((Double(cleanableCount) * 0.4).rounded(.up))
                    let favNote = favorites.isEmpty ? "" : "，已收藏的条目将保留"
                    let alert = NSAlert()
                    alert.messageText = "清理前 40% 的剪贴板历史?"
                    alert.informativeText = "将从 \(total) 条记录中移除最旧的 \(estimated) 条（约前 40%\(favNote)），且无法撤销。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "确认清理")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        let removed = backend.trimOldestPercent(40)
                        if removed > 0 { debugLog("Trimmed \(removed) oldest entries (40%)") }
                    }
                } label: {
                    Label("清理前 40% 历史", systemImage: "arrow.up.trash")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.orange)

                Button(role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "清除所有剪贴板历史?"
                    alert.informativeText = "此操作会删除所有已保存的剪贴板记录，且无法撤销。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "确认清除")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        backend.clearHistory()
                    }
                } label: {
                    Label("清除所有历史", systemImage: "trash")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .alert("确认调整清理阈值?", isPresented: Binding<Bool>(
            get: { pendingThreshold != nil },
            set: { if !$0 { pendingThreshold = nil } }
        )) {
            Button("确认调整") {
                if let val = pendingThreshold {
                    cleanupThreshold = Double(val)
                    backend.setCleanupThreshold(val)
                }
                pendingThreshold = nil
            }
            Button("取消", role: .cancel) {
                pendingThreshold = nil
            }
        } message: {
            if let val = pendingThreshold {
                Text("当前已有 \(backend.items.count) 条记录。阈值降至 \(val) 条后，超出部分将被自动清理。是否继续？")
            }
        }
    }

    // MARK: - 💾 Backup & Restore Card

    private var backupRestoreCard: some View {
        settingsCard {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 16))
                    .foregroundColor(Color.accentColor)
                Text("备份与恢复")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if let msg = backupStatusMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .systemGreen))
                        Text(msg)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(nsColor: .systemGreen))
                    }
                    .transition(.opacity)
                }

                Spacer()
            }
            .padding(.bottom, 12)

            HStack(spacing: 12) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 15))
                    .foregroundColor(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("导出备份")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("将全部剪贴板历史、收藏与备注保存为独立文件。")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button("导出备份...") {
                    handleExportBackup()
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)

            sectionDivider().padding(.vertical, 7)

            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 15))
                    .foregroundColor(Color(nsColor: .systemGreen))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("从备份恢复")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("从备份文件中恢复记录，支持与现有历史合并。")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button("恢复备份...") {
                    handleImportBackup()
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private func showBackupStatus(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            backupStatusMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if backupStatusMessage == message {
                    backupStatusMessage = nil
                }
            }
        }
    }

    private func handleExportBackup() {
        let savePanel = NSSavePanel()
        savePanel.title = "导出剪贴板备份"
        savePanel.prompt = "导出"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        savePanel.nameFieldStringValue = "CopyAttach_\(dateStr).cabackup"

        if #available(macOS 11.0, *) {
            if let type = UTType(filenameExtension: "cabackup") {
                savePanel.allowedContentTypes = [type, .database, .data]
            }
        }

        savePanel.begin { response in
            guard response == .OK, let targetURL = savePanel.url else { return }
            do {
                let count = try backend.exportBackup(to: targetURL)
                showBackupStatus("已成功备份 \(count) 条记录")
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    private func handleImportBackup() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择 CopyAttach 备份文件"
        openPanel.prompt = "选择"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if #available(macOS 11.0, *) {
            if let type = UTType(filenameExtension: "cabackup") {
                openPanel.allowedContentTypes = [type, .database, .data]
            }
        }

        openPanel.begin { response in
            guard response == .OK, let backupURL = openPanel.url else { return }

            do {
                let info = try backend.inspectBackup(at: backupURL)
                let timeStr = DateFormatter.localizedString(from: info.createdAt, dateStyle: .medium, timeStyle: .short)

                let alert = NSAlert()
                alert.messageText = "要如何恢复剪贴板历史？"
                alert.informativeText = "备份创建于 \(timeStr)，包含 \(info.totalItems) 条记录（\(info.favoriteItems) 条收藏）。\n\n您可以将备份内容与现有历史合并，或完全替换当前内容。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "合并")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "替换...")

                let choice = alert.runModal()
                if choice == .alertFirstButtonReturn {
                    let count = try backend.restoreBackup(from: backupURL, mode: .merge)
                    showBackupStatus("已合并恢复（新增 \(count) 条记录）")
                } else if choice == .alertThirdButtonReturn {
                    let confirmAlert = NSAlert()
                    confirmAlert.messageText = "确定要替换所有剪贴板记录吗？"
                    confirmAlert.informativeText = "当前历史将被备份中的 \(info.totalItems) 条记录完全替换。此操作无法撤销。"
                    confirmAlert.alertStyle = .critical
                    confirmAlert.addButton(withTitle: "替换")
                    confirmAlert.addButton(withTitle: "取消")

                    if confirmAlert.runModal() == .alertFirstButtonReturn {
                        let count = try backend.restoreBackup(from: backupURL, mode: .overwrite)
                        showBackupStatus("已全量恢复备份（共 \(count) 条记录）")
                    }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法打开备份文件"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }
}
