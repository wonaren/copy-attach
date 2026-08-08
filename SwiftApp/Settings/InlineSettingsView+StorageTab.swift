import SwiftUI

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
                    .foregroundColor(theme.tertiaryText)
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
                                Color.green
                                    .frame(width: w * imagePct)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 12)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                            Circle().fill(Color.green).frame(width: 8, height: 8)
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
                        .foregroundColor(theme.tertiaryText)
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
                    let estimated = Int((Double(total) * 0.4).rounded(.up))
                    guard total > 0 else { return }
                    let alert = NSAlert()
                    alert.messageText = "清理前 40% 的剪贴板历史?"
                    alert.informativeText = "将从 \(total) 条记录中移除最旧的 \(estimated) 条（约前 40%），且无法撤销。"
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
}
