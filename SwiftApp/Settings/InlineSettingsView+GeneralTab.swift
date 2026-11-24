import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

extension InlineSettingsView {
    var generalTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !backend.permissionGranted && autoPasteAtCursor {
                    permissionBanner
                }
                generalSettingsCard
            }
            .padding(20)
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: backend.permissionGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 18))
                    .foregroundColor(backend.permissionGranted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                Text(backend.permissionGranted ? "辅助功能：已授权" : "辅助功能：未授权")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(backend.permissionGranted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
            }
            if !backend.permissionGranted {
                Text("应用需要辅助功能权限才能自动粘贴（模拟 ⌘V）；唤出快捷键无需授权即可使用。")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }
            if !backend.permissionGranted && !showDragGuide {
                Button(action: {
                    backend.openPreferences()
                    withAnimation(ReduceMotion.animation(.spring(response: 0.35, dampingFraction: 0.72))) {
                        showDragGuide = true
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("打开系统设置 → 授予权限")
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .transition(ReduceMotion.transition(.opacity.combined(with: .move(edge: .top))))
            }
            if showDragGuide && !backend.permissionGranted {
                dragGuideContent
                    .transition(ReduceMotion.transition(.opacity.combined(with: .move(edge: .top))))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backend.permissionGranted ? Color(nsColor: .systemGreen).opacity(0.10) : Color(nsColor: .systemOrange).opacity(0.10))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(backend.permissionGranted ? Color(nsColor: .systemGreen).opacity(0.28) : Color(nsColor: .systemOrange).opacity(0.28), lineWidth: 1)
        )
        .animation(ReduceMotion.animation(.spring(response: 0.3, dampingFraction: 0.72)), value: showDragGuide)
        .animation(ReduceMotion.animation(.spring(response: 0.3, dampingFraction: 0.72)), value: backend.permissionGranted)
        .onChange(of: backend.permissionGranted) { _, granted in
            if granted {
                withAnimation(ReduceMotion.animation(.spring(response: 0.3, dampingFraction: 0.72))) {
                    showDragGuide = false
                }
            }
        }
    }

    private var dragGuideContent: some View {
        VStack(spacing: 12) {
            Color.orange.opacity(0.15)
                .frame(height: 1)
                .padding(.horizontal, -16)

            HStack(spacing: 14) {
                ZStack {
                    Image(nsImage: .appIconSVG ?? .appIcon)
                        .resizable()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "hand.point.up")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 5, y: -5)
                                .allowsHitTesting(false)
                        }
                        .scaleEffect(isHoveringDragIcon ? ReduceMotion.scale(1.05) : 1.0)
                        .onHover { hovering in
                            withAnimation(ReduceMotion.animation(.easeInOut(duration: 0.2))) {
                                isHoveringDragIcon = hovering
                            }
                        }
                        .onDrag {
                            let provider = NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                            provider.suggestedName = "CopyAttach"
                            return provider
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("将图标拖入系统辅助功能列表")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("已打开「系统设置 → 隐私与安全性 → 辅助功能」")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.secondaryText)
                    Button(action: { backend.openPreferences() }) {
                        Text("再次打开系统设置")
                            .font(.system(size: 10.5))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }

                Spacer()

                Button(action: {
                    withAnimation(ReduceMotion.animation(.spring(response: 0.3, dampingFraction: 0.72))) {
                        showDragGuide = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var generalSettingsCard: some View {
        settingsCard {
            settingToggleRow(
                icon: launchAtLogin ? "power.circle.fill" : "power.circle",
                iconColor: launchAtLogin ? Color(nsColor: .systemGreen) : theme.secondaryText,
                title: "开机启动",
                desc: "在 macOS 系统启动时自动开启 CopyAttach。",
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "LaunchAtLogin")
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    debugLog("Failed to update login item: \(error)")
                    launchAtLogin = !newValue
                    UserDefaults.standard.set(!newValue, forKey: "LaunchAtLogin")
                }
            }
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: runInBackground ? "circle.fill" : "circle",
                iconColor: runInBackground ? Color(nsColor: .systemGreen) : theme.secondaryText,
                title: "后台运行",
                desc: "关闭设置面板后，保持应用在菜单栏与后台继续运行。",
                isOn: $runInBackground
            )
            .onChange(of: runInBackground) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "RunInBackground")
            }
            sectionDivider().padding(.vertical, 7)
            windowBackgroundRow
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: "menubar.rectangle",
                iconColor: showMenuBarIcon ? Color.accentColor : theme.secondaryText,
                title: "显示菜单栏图标",
                desc: "控制 CopyAttach 图标在 macOS 顶部状态栏的显示与隐藏。",
                isOn: $showMenuBarIcon
            )
            .onChange(of: showMenuBarIcon) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "ShowMenuBarIcon")
            }
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: "ant.circle.fill",
                iconColor: debugLogging ? Color(nsColor: .systemOrange) : theme.secondaryText,
                title: "调试日志",
                desc: "记录诊断日志到 /tmp/copyattach_debug.log；默认关闭。",
                isOn: $debugLogging
            )
            .onChange(of: debugLogging) { _, newValue in
                backend.setDebugLogging(newValue)
            }
        }
    }

    private var systemForcesOpaqueBackground: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    private var effectivePopupBackgroundOpacity: Double {
        min(max(popupBackgroundOpacity, HistoryPopupContent.popupBackgroundOpacityRange.lowerBound),
            HistoryPopupContent.popupBackgroundOpacityRange.upperBound)
    }

    private var displayedPopupBackgroundOpacity: Double {
        systemForcesOpaqueBackground ? 1.0 : effectivePopupBackgroundOpacity
    }

    private var windowBackgroundRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(systemForcesOpaqueBackground ? theme.secondaryText : Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("弹窗不透明度")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(systemForcesOpaqueBackground
                         ? "系统已开启降低透明度，背景保持不透明。"
                         : effectivePopupBackgroundOpacity < 0.6
                            ? "已很透明：文字会变淡。"
                            : "透出模糊的桌面背景。")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Slider(value: $popupBackgroundOpacity,
                       in: HistoryPopupContent.popupBackgroundOpacityRange,
                       step: 0.1)
                    .frame(width: 150)
                    .disabled(systemForcesOpaqueBackground)
                Text("\(Int((displayedPopupBackgroundOpacity * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 34, alignment: .trailing)
            }
            windowBackgroundPreview
                .padding(.leading, 34)
        }
        .padding(.vertical, 4)
    }

    private var windowBackgroundPreview: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.30, green: 0.55, blue: 0.95),
                Color(red: 0.95, green: 0.72, blue: 0.35),
                Color(red: 0.40, green: 0.78, blue: 0.55)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.regularMaterial)
            theme.popupBackground.opacity(systemForcesOpaqueBackground ? 1.0 : effectivePopupBackgroundOpacity)
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.popupSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("示例条目")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.popupPrimaryText)
                    Text("背景越不透明，文字越清晰")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.popupSecondaryText)
                }
                Spacer()
                Text("刚刚")
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.popupMutedText)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
        )
    }
}
