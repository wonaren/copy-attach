import SwiftUI
import ServiceManagement

// MARK: - 🔵 GENERAL TAB

extension InlineSettingsView {
    var generalTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                permissionBanner
                generalSettingsCard
                menuBarConfigCard
            }
            .padding(20)
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — always visible
            HStack(spacing: 10) {
                Image(systemName: backend.permissionGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 18))
                    .foregroundColor(backend.permissionGranted ? .green : .orange)
                Text(backend.permissionGranted ? "辅助功能：已授权" : "辅助功能：未授权")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(backend.permissionGranted ? .green : .orange)
            }
            if !backend.permissionGranted {
                Text("应用需要辅助功能权限才能使用全局快捷键和自动粘贴")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }
            if !backend.permissionGranted && !showDragGuide {
                Button(action: {
                    backend.openPreferences()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showDragGuide && !backend.permissionGranted {
                dragGuideContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backend.permissionGranted ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(backend.permissionGranted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: showDragGuide)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: backend.permissionGranted)
        .onChange(of: backend.permissionGranted) { _, granted in
            if granted {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
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
                        }
                        .scaleEffect(isHoveringDragIcon ? 1.05 : 1.0)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
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
            cardTitle(icon: "gearshape.2", text: "其它设置")
            settingToggleRow(
                icon: launchAtLogin ? "power.circle.fill" : "power.circle",
                iconColor: launchAtLogin ? .green : .secondary,
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
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(
                icon: runInBackground ? "circle.fill" : "circle",
                iconColor: runInBackground ? .green : .secondary,
                title: "后台运行",
                desc: "关闭主窗口后，保持应用在后台状态栏运行。",
                isOn: $runInBackground
            )
            .onChange(of: runInBackground) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "RunInBackground")
            }
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(
                icon: closePopupAfterDrag ? "hand.draw.fill" : "hand.draw",
                iconColor: closePopupAfterDrag ? Color.accentColor : .secondary,
                title: "拖拽后自动关闭弹窗",
                desc: "将历史条目拖拽到其他应用后自动关闭弹窗；关闭此开关可连续拖拽多个条目。",
                isOn: $closePopupAfterDrag
            )
            .onChange(of: closePopupAfterDrag) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: HistoryPopupWindow.closePopupAfterDragDefaultsKey)
            }
        }
    }

    private var menuBarConfigCard: some View {
        settingsCard {
            cardTitle(icon: "menubar.rectangle", text: "菜单栏图标状态设置")
            settingToggleRow(
                icon: "dot.square",
                iconColor: showMenuBarIcon ? Color.accentColor : .secondary,
                title: "显示菜单栏图标",
                desc: "控制 CopyAttach 图标在 macOS 右上角状态栏的显隐。",
                isOn: $showMenuBarIcon
            )
            .onChange(of: showMenuBarIcon) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "ShowMenuBarIcon")
            }
        }
    }
}
