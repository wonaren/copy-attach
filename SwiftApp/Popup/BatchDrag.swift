import AppKit
import ApplicationServices
import SwiftUI

enum DropTargetResolver {
    struct Target {
        let pid: pid_t
        let name: String
    }

    static func target(at cocoaPoint: NSPoint) -> Target? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            debugLog("BatchDrag: no screen available")
            return nil
        }
        let cgPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        guard let pid = axPID(at: cgPoint) else {
            debugLog("BatchDrag: AX found no element at \(cgPoint)")
            return nil
        }
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            debugLog("BatchDrag: drop point \(cgPoint) resolves to this app")
            return nil
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            debugLog("BatchDrag: AX pid \(pid) has no running application")
            return nil
        }
        guard app.activationPolicy == .regular else {
            debugLog("BatchDrag: \(app.localizedName ?? "pid \(pid)") is not a regular app (policy \(app.activationPolicy.rawValue))")
            return nil
        }
        return Target(pid: pid, name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)")
    }

    private static func axPID(at cgPoint: CGPoint) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(cgPoint.x), Float(cgPoint.y), &element)
        guard err == .success, let element else {
            debugLog("BatchDrag: AX at \(cgPoint) err=\(err.rawValue)")
            return nil
        }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "?"
        if role == "AXMenuBar" || role == "AXMenuBarItem" || role == "AXMenuItem" || role == "AXMenu" {
            debugLog("BatchDrag: AX at \(cgPoint) role=\(role) is not a drop target")
            return nil
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        debugLog("BatchDrag: AX at \(cgPoint) pid=\(pid) role=\(role)")
        return pid > 0 ? pid : nil
    }
}

@MainActor
final class BatchDragController {
    static let shared = BatchDragController()

    private(set) var isActive = false

    private var items: [ClipboardItem] = []

    private var activationTask: Task<Void, Never>?

    private init() {}

    func begin(items: [ClipboardItem]) {
        activationTask?.cancel()
        activationTask = nil
        guard items.count > 1 else {
            cancel()
            return
        }
        self.items = items
        isActive = true
        debugLog("BatchDrag: drag started with \(items.count) items")
    }

    func cancel() {
        guard isActive || !items.isEmpty else { return }
        debugLog("BatchDrag: cancelled with \(items.count) items pending")
        isActive = false
        items = []
    }

    var isDispatching: Bool {
        activationTask != nil || BatchDispenseRunner.shared.isRunning
    }

    func abortPendingDispatch() {
        activationTask?.cancel()
        activationTask = nil
        BatchDispenseRunner.shared.cancel()
    }

    func dragEnded(at cocoaPoint: NSPoint, popupFrame: NSRect) {
        guard isActive else { return }
        isActive = false
        items = []
        activationTask?.cancel()
        activationTask = nil

        guard !popupFrame.contains(cocoaPoint) else {
            debugLog("BatchDrag: drop point is inside the popup; treated as cancel")
            return
        }

        let pruned = PasteQueueManager.shared.pruneStaleEntries()
        let live = PasteQueueManager.shared.queueItems
        if pruned > 0 {
            debugLog("BatchDrag: pruned \(pruned) stale queued item(s) before dispatch")
        }
        guard live.count > 1 else {
            debugLog("BatchDrag: only \(live.count) live queued item(s); not dispatching")
            abortDispatch("队列项已失效，未发送")
            return
        }

        guard ClipboardBackend.shared.checkPermission() else {
            debugLog("BatchDrag: accessibility not granted; nothing dispatched")
            abortDispatch("批量粘贴需要辅助功能权限")
            return
        }

        guard let target = DropTargetResolver.target(at: cocoaPoint) else {
            debugLog("BatchDrag: no drop target at \(cocoaPoint); queue untouched")
            abortDispatch("未找到可粘贴的目标应用")
            return
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        debugLog("BatchDrag: target \(target.name) (pid \(target.pid)), frontmost=\(front ?? -1), cocoa=\(cocoaPoint), items=\(live.count)")
        if front == target.pid {
            startDispatch(items: live, target: target)
            return
        }

        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            abortDispatch("目标应用已退出")
            return
        }
        activationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            guard app.activate() else {
                debugLog("BatchDrag: failed to activate \(target.name) (pid \(target.pid))")
                self.activationTask = nil
                self.abortDispatch("无法激活目标应用")
                return
            }
            var activated = false
            for _ in 0..<10 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
                    activated = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
            }
            guard activated else {
                let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
                debugLog("BatchDrag: activation did not stick: frontmost=\(now ?? -1), target=\(target.pid)")
                self.activationTask = nil
                self.abortDispatch("目标应用未激活，未发送")
                return
            }
            debugLog("BatchDrag: activated \(target.name) (pid \(target.pid))")
            self.activationTask = nil
            self.startDispatch(items: live, target: target)
        }
    }

    private func abortDispatch(_ message: String) {
        BatchHUDNotice.shared.show(message)
        if PasteQueueManager.shared.hasItems {
            PasteQueueManager.shared.markPendingBatchRetry()
        }
    }

    private func startDispatch(items: [ClipboardItem], target: DropTargetResolver.Target) {
        debugLog("BatchDrag: dispatching \(items.count) item(s) to \(target.name) (pid \(target.pid))")
        BatchDispenseRunner.shared.start(
            items: items,
            targetPID: target.pid,
            batchSize: items.count
        )
    }
}

struct DragChip: View {
    let item: ClipboardItem
    let count: Int
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if !item.sourceBundleId.isEmpty, let icon = getAppIcon(for: item.sourceBundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                Image(systemName: item.isImage ? "photo.fill" : "doc.text.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.popupSecondaryText)
                    .frame(width: 18, height: 18)
            }
            Text(chipLabel)
                .font(.system(size: 12.5))
                .foregroundColor(theme.popupPrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if count > 1 {
                Text("\(count) 条")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.16) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.popupRowBorder, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 3)
    }

    private var chipLabel: String {
        if item.isImage {
            return item.hasCustomLabel ? item.customLabel : "图片"
        }
        return item.displayPreview
    }
}
