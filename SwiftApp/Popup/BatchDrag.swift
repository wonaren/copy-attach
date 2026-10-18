import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Drop target resolution

/// Resolves the app that owns the drop point.
///
/// The drop point is the user's intent; `NSWorkspace.frontmostApplication` is
/// not. Measured on this machine: with TextEdit frontmost, a queued batch
/// dropped over a visible window at (1100, 300) made the old "frontmost + any
/// of its windows contains the point" check find no TextEdit window and
/// silently drop the batch. The window list alone is also wrong:
/// `.optionOnScreenOnly` reports windows from other Spaces with identical
/// full-screen bounds (four apps all reported 0,33 1470×923), so "first window
/// containing the point" can name an app the user cannot see.
///
/// `AXUIElementCopyElementAtPosition` is the authoritative signal: it returns
/// the topmost accessibility element at the point (measured: Ghostty's
/// `AXTextArea` at (1100,300) while TextEdit was frontmost; TextEdit's
/// `AXTextArea` at (1200,300) once its window was visible there). It is only
/// used outside our own popup — inside the popup it resolves to the app behind
/// us, which is why the caller checks `popupFrame` first. If AX returns nothing
/// (an app with no accessibility tree), the batch is refused with a notice
/// instead of guessing another app; guessing is exactly how a batch lands in a
/// window the user did not drop on.
enum DropTargetResolver {
    struct Target {
        let pid: pid_t
        let name: String
    }

    /// Drop point in Cocoa screen coordinates (`NSEvent.mouseLocation`).
    static func target(at cocoaPoint: NSPoint) -> Target? {
        // Cocoa (bottom-left origin) -> CG (top-left origin of the primary screen)
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
        // Menus, the Dock and system UI are not paste targets. Accessory/HUD
        // windows either have no editable focus or swallow ⌘V silently.
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

// MARK: - Controller

/// Owns the "this drag carries the whole queued set" state, and turns the drop
/// into a dispatch.
///
/// The set is `PasteQueueManager.queueItems` — the queue is the app's one
/// ordered multi-selection (badges show the order), so batch drag introduces no
/// second selection model. The drag payload is an empty placeholder (see
/// `BatchDragPlan`); every item travels through `BatchDispenseRunner`.
@MainActor
final class BatchDragController {
    static let shared = BatchDragController()

    /// True between `.onDrag` firing and the drag ending (mouse-up or the popup
    /// resigning key).
    private(set) var isActive = false

    /// Ordered snapshot taken at drag start.
    private var items: [ClipboardItem] = []

    /// Pending activation of a target that the drop did not bring forward.
    private var activationTask: Task<Void, Never>?

    private init() {}

    /// Called from the row's `.onDrag` when the dragged row is part of a
    /// multi-item queue.
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

    /// Abandon an armed drag. Deliberately does NOT touch a dispatch that
    /// `dragEnded` already committed to: `HistoryPopupWindow.close()` calls this
    /// on every close, and cancelling the activation task here would silently
    /// drop a legitimate batch.
    func cancel() {
        guard isActive || !items.isEmpty else { return }
        debugLog("BatchDrag: cancelled with \(items.count) items pending")
        isActive = false
        items = []
    }

    /// True while a batch is waiting for target activation or pasting. The popup
    /// uses this to cancel the whole sequence when the user summons history.
    var isDispatching: Bool {
        activationTask != nil || BatchDispenseRunner.shared.isRunning
    }

    /// Stop a dispatch that is still waiting for target activation (or, through
    /// the runner, one that is already sending). Used when the user reopens the
    /// popup while a batch is starting.
    func abortPendingDispatch() {
        activationTask?.cancel()
        activationTask = nil
        BatchDispenseRunner.shared.cancel()
    }

    /// Called by the popup on BOTH drag-end exits: `completeItemDrag` (mouse-up
    /// while the popup is still key) and `didResignKey` (the drop activated
    /// another app). Idempotent — the first call wins.
    func dragEnded(at cocoaPoint: NSPoint, popupFrame: NSRect) {
        guard isActive else { return }
        isActive = false
        items = []
        activationTask?.cancel()
        activationTask = nil

        // A drop onto our own popup is not a drop into another app. Refuse
        // before anything is pasted.
        guard !popupFrame.contains(cocoaPoint) else {
            debugLog("BatchDrag: drop point is inside the popup; treated as cancel")
            return
        }

        // Revalidate against the live history before committing. A queued entry
        // can disappear while the list is open (history trim, external delete);
        // the queue is the selection, so a stale item must not abort the batch at
        // item K and leave the rest unreachable.
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

        // `prepare_paste` refuses without Accessibility, but only after it has
        // written the pasteboard — on the second item of a batch that reads as a
        // half-delivered set. Check first so the failure is one explicit notice.
        // It must come before AX: `AXUIElementCopyElementAtPosition` also needs
        // Accessibility and would otherwise be reported as "no target".
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

        // The empty placeholder drop often does not activate the target
        // (measured: TextEdit/Notes reject the empty payload). A synthesized ⌘V
        // is only meaningful in the frontmost app, so bring the app named by the
        // drop point forward explicitly. The task waits for the popup close and
        // any focus restore it performs before activating.
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
            // Activation is asynchronous and a large app can take a few hundred
            // milliseconds to become frontmost. Poll instead of one fixed sleep:
            // a premature "not activated" would refuse a legitimate cross-app drop.
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

    /// A dispatch that never started is still a staged selection: keep it for a
    /// retry instead of letting the next popup open clear it.
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

// MARK: - Drag preview

/// The drag image for every row drag: a single entry, or a batch whose payload
/// is only its first item.
///
/// One view type serves both cases on purpose. Picking between two preview
/// types in the row's body gave the row two possible view types, and every flip
/// (the queue crossing 1 -> 2 entries) rebuilt the row subtree and replayed its
/// transitions. The count capsule appears only when more than one entry will be
/// delivered: the payload is a single pasteboard item, so the drag cannot show N
/// stacked row images (one `NSDraggingItem` per pasteboard item), and "N 条" is
/// the honest representation of "one payload, N to follow".
struct DragChip: View {
    let item: ClipboardItem
    /// How many entries the drop delivers; 1 for an ordinary single-entry drag.
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
