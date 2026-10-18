import AppKit
import SwiftUI

// MARK: - Drop target resolution

/// Resolves the app that must receive the rest of the batch.
///
/// Two candidates were measured on this machine before settling on this one:
///
/// 1. `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` z-order: the list
///    contains windows from OTHER Spaces (four maximised apps — Hermes / Code /
///    Arc / Ghostty — all reported at the identical bounds 0,33 1470×923 while
///    only one was visible), so "first window containing the point" can name an
///    app the user cannot see.
/// 2. `AXUIElementCopyElementAtPosition`: works over plain AppKit content
///    (measured: TextEdit → `AXTextArea`, Hermes → `AXButton`) but fails over
///    SwiftUI opaque lists (measured `err=-25208` inside our own popup) and,
///    worse, silently resolves to whatever app is BEHIND our popup when the
///    point is over it.
///
/// So the target is the *frontmost* app — the only app a synthesized ⌘V can
/// sensibly address — and the window list is used merely to prove the drop
/// point really is over one of that app's windows (geometry only, no z-order
/// reasoning).
enum DropTargetResolver {
    struct Target {
        let pid: pid_t
        let name: String
    }

    /// Drop point in Cocoa screen coordinates (`NSEvent.mouseLocation`).
    static func target(at cocoaPoint: NSPoint) -> Target? {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            debugLog("BatchDrag: no frontmost application")
            return nil
        }
        let pid = front.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            debugLog("BatchDrag: frontmost app is this app")
            return nil
        }
        // Cocoa (bottom-left origin) -> CG (top-left origin of the primary screen)
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            debugLog("BatchDrag: no screen available")
            return nil
        }
        let cgPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        guard window(ofPID: pid, contains: cgPoint) else {
            debugLog("BatchDrag: drop point \(cgPoint) is not over a window of \(front.localizedName ?? "?")")
            return nil
        }
        return Target(pid: pid, name: front.localizedName ?? "?")
    }

    private static func window(ofPID pid: pid_t, contains cgPoint: CGPoint) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in raw {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int,
                  pid_t(owner) == pid,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            if bounds.contains(cgPoint) { return true }
        }
        return false
    }
}

// MARK: - Controller

/// Owns the "this drag carries the whole queued set" state, and turns the drop
/// into a dispatch.
///
/// The set is `PasteQueueManager.queueItems` — the queue is the app's one
/// ordered multi-selection (badges show the order), so batch drag introduces no
/// second selection model. Only the *leading* item travels in the drag payload;
/// the rest follow as synthesized ⌘V keystrokes (see `BatchDispenseRunner`).
@MainActor
final class BatchDragController {
    static let shared = BatchDragController()

    /// True between `.onDrag` firing and the drag ending (mouse-up or the popup
    /// resigning key).
    private(set) var isActive = false

    /// Ordered snapshot taken at drag start. The drag payload is an empty
    /// placeholder, so every item is still to send (see `BatchDragPlan`).
    private var items: [ClipboardItem] = []

    private init() {}

    /// Called from the row's `.onDrag` when the dragged row is part of a
    /// multi-item queue.
    func begin(items: [ClipboardItem]) {
        guard items.count > 1 else {
            cancel()
            return
        }
        self.items = items
        isActive = true
        debugLog("BatchDrag: drag started with \(items.count) items")
    }

    /// Abandon the pending batch without dispatching (single-item drag, popup
    /// dismissed, another batch began).
    func cancel() {
        guard isActive || !items.isEmpty else { return }
        debugLog("BatchDrag: cancelled with \(items.count) items pending")
        isActive = false
        items = []
    }

    /// Called by the popup on BOTH drag-end exits: `completeItemDrag` (mouse-up
    /// while the popup is still key) and `didResignKey` (the drop activated
    /// another app). Idempotent — the first call wins.
    func dragEnded(at cocoaPoint: NSPoint, popupFrame: NSRect) {
        guard isActive else { return }
        let snapshot = items
        isActive = false
        items = []
        guard snapshot.count > 1 else { return }

        // A drop onto our own popup is not a drop into another app: this panel is
        // non-activating, so the "frontmost" app reported at that moment is
        // whatever sits BEHIND it. Refuse before anything is pasted.
        guard !popupFrame.contains(cocoaPoint) else {
            debugLog("BatchDrag: drop point is inside the popup; treated as cancel")
            return
        }
        guard let target = DropTargetResolver.target(at: cocoaPoint) else {
            debugLog("BatchDrag: no drop target at \(cocoaPoint); queue untouched")
            return
        }
        // `prepare_paste` refuses without Accessibility, but only after it has
        // written the pasteboard — on the second item of a batch that reads as a
        // half-delivered set. Check first so the failure is one explicit notice.
        guard ClipboardBackend.shared.checkPermission() else {
            debugLog("BatchDrag: accessibility not granted; only the payload was delivered")
            BatchHUDNotice.shared.show("批量粘贴需要辅助功能权限")
            return
        }

        debugLog("BatchDrag: dispatching \(snapshot.count) item(s) to \(target.name) (pid \(target.pid))")
        BatchDispenseRunner.shared.start(
            items: snapshot,
            targetPID: target.pid,
            batchSize: snapshot.count,
            sentSoFar: 0
        )
    }
}

// MARK: - Drag preview

/// The drag image for a batch: the leading item plus the batch size.
///
/// The payload is a single pasteboard item, so the drag cannot show N stacked
/// row images (one `NSDraggingItem` per pasteboard item). A single chip stated
/// as "N 条" is the honest representation of "one payload, N to follow".
struct BatchDragChip: View {
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
            Text("\(count) 条")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                .fixedSize()
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
