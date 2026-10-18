import AppKit
import SwiftUI

// MARK: - Right-Click Context Menu

extension HistoryPopupContent {
    /// The current displayItems index of the entry, or nil if it no longer
    /// exists (deleted, filtered out, or the list changed while the menu was
    /// open). Actions re-resolve by stable entry id instead of trusting the
    /// index captured when the menu was built.
    private func currentIndex(of entryId: Int) -> Int? {
        displayItems.firstIndex(where: { $0.id == entryId })
    }

    /// Resolve an armed right-click against the one-shot row-frame snapshot.
    /// Disarms unconditionally (the snapshot is single-use); presents the
    /// menu only when the click landed on a row. Presentation hops to the
    /// next runloop tick — the preference callback runs inside a SwiftUI
    /// layout pass, and NSMenu.popUp must not start mid-update.
    func resolveContextMenu(frames: [Int: CGRect], request: PopupContextMenuRequest) {
        guard let (entryId, _) = frames.first(where: { $0.value.contains(request.viewPoint) }) else {
            return
        }
        let resolved = PopupContextMenuRequest(entryId: entryId,
                                               viewPoint: request.viewPoint,
                                               windowPoint: request.windowPoint)
        DispatchQueue.main.async { [self] in
            // The popup may have closed or the row may have been filtered out
            // during the async gap — re-resolve by stable id before presenting.
            guard currentIndex(of: entryId) != nil else { return }
            showContextMenu(for: resolved)
        }
    }

    /// Presented by `PopupHostingView.rightMouseDown` via notification.
    /// Selects the right-clicked row, then shows a native NSMenu at the cursor.
    private func showContextMenu(for request: PopupContextMenuRequest) {
        guard let entryId = request.entryId,
              let index = currentIndex(of: entryId) else { return }
        let item = displayItems[index]
        selectedIndex = min(index + 1, maxIndex)

        let menu = NSMenu()
        menu.autoenablesItems = false

        addContextMenuItem(to: menu, title: "插入", symbol: "arrow.down.to.line") {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.selectedIndex = idx + 1
            self.selectItem(at: idx)
        }
        addContextMenuItem(to: menu, title: "预览", symbol: "eye") {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.selectedIndex = idx + 1
            if self.showPreview {
                self.updatePreviewContent()
            } else {
                self.openPreview()
            }
        }
        menu.addItem(.separator())
        addContextMenuItem(to: menu,
                           title: item.isImage ? "复制图片" : "复制内容",
                           symbol: item.isImage ? "photo" : "doc.on.doc") {
            if self.copyItemContent(item) {
                self.showToast("已复制到剪贴板", icon: "checkmark.circle.fill")
            }
        }
        let inQueue = PasteQueueManager.shared.order(of: item) != nil
        addContextMenuItem(to: menu,
                           title: inQueue ? "移出粘贴队列" : "加入粘贴队列",
                           symbol: "list.number") {
            withAnimation(AppleMotion.snappy) {
                PasteQueueManager.shared.toggle(item)
            }
            OnboardingGuide.shared.record(.queueToggled)
        }
        if item.isImage {
            addContextMenuItem(to: menu, title: "另存为…", symbol: "square.and.arrow.down") {
                self.saveImageItem(item)
            }
        }
        menu.addItem(.separator())
        let isFavorite = backend.favoriteIds.contains(item.id)
        addContextMenuItem(to: menu,
                           title: isFavorite ? "取消收藏" : "收藏",
                           symbol: isFavorite ? "star.slash" : "star") {
            if self.backend.toggleFavorite(item.id) {
                self.showToast(!isFavorite ? "已加入收藏" : "已取消收藏", icon: !isFavorite ? "star.fill" : "star.slash.fill")
            } else {
                self.showToast("收藏失败，请重试", icon: "exclamationmark.triangle.fill")
            }
            // Favorites may shrink displayItems; keep the selection valid.
            if self.selectedIndex > self.maxIndex {
                self.selectedIndex = max(0, self.maxIndex)
            }
        }
        let hasRemark = item.hasCustomLabel
        addContextMenuItem(to: menu,
                           title: hasRemark ? "编辑备注…" : "添加备注…",
                           symbol: "pencil.line") {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.selectedIndex = idx + 1
            self.startInlineEditing(for: item)
        }
        addContextMenuItem(to: menu, title: "删除", symbol: "trash", destructive: true) {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.deleteItem(at: idx)
        }

        guard let popup = popupWindow, let contentView = popup.contentView else { return }
        let point = contentView.convert(request.windowPoint, from: nil)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    private func addContextMenuItem(to menu: NSMenu, title: String, symbol: String,
                                    destructive: Bool = false, action: @escaping () -> Void) {
        let handler = ContextMenuItemTarget(action)
        let item = NSMenuItem(title: title,
                              action: #selector(ContextMenuItemTarget.invoke(_:)),
                              keyEquivalent: "")
        item.target = handler
        // NSMenuItem.target is weak; representedObject (strong) keeps the
        // handler alive for as long as the menu owns the item.
        item.representedObject = handler
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(item)
    }

    /// Copy the entry's full content to the system pasteboard without pasting.
    /// Returns true on success, false if the payload could not be loaded or materialized.
    @discardableResult
    private func copyItemContent(_ item: ClipboardItem) -> Bool {
        switch item {
        case .text:
            guard let full = item.fullText else {
                debugLog("copyItemContent: failed to load full text for entry \(item.id)")
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(full, forType: .string)
            return true
        case .image:
            guard let data = item.imageData else {
                debugLog("copyItemContent: image not ready (entry \(item.id))")
                return false
            }
            // File-URL clipboard write — the same convention as the paste and
            // drag paths. Putting the raw PNG DATA on the pasteboard instead
            // makes the pasteboard machinery eagerly decode the full image
            // in-process and keep a TIFF representation alive per write
            // (measured: every image-data write pins ~2 full-size RGBA
            // buffers forever, across NSPasteboard, NSPasteboardItem, AND the
            // raw CorePasteboard API — 29 copies ≈ 320MB of permanent
            // resident memory). A file-URL string write costs bytes and is
            // consumed exactly like a Finder file copy: notes/chat apps
            // attach the file, terminals and TUI agents get the path text.
            // The file lives OUTSIDE the CopyAttach temp root
            // (`CopyAttach-copy/`), so the monitor re-captures it (dedup
            // keeps the entry and moves it to top — the same re-copy
            // semantics as the old data write) instead of skipping it as a
            // self-materialization.
            let url: URL
            do {
                url = try Self.copyImageURL(entryId: item.id)
                try data.write(to: url, options: .atomic)
            } catch {
                debugLog("copyItemContent: failed to materialize copy image \(item.id): \(error)")
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .fileURL)
            return true
        }
    }

    /// Destination for a copied image's temp PNG. Purges previous copy
    /// artifacts past the in-flight window: only the newest URL can still
    /// reference the pasteboard, and a paste target may read it asynchronously
    /// (mirrors the Rust paste-file TTL).
    private static func copyImageURL(entryId: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyAttach-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ttl: TimeInterval = 60
        let now = Date()
        for url in try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(mtime) > ttl {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return dir.appendingPathComponent("clipboard-\(entryId)-\(UUID().uuidString).png")
    }

    /// Save an image entry to a user-chosen location as a PNG file.
    private func saveImageItem(_ item: ClipboardItem) {
        guard item.isImage, let data = item.imageData else { return }
        let timestamp = item.timestamp
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        panel.nameFieldStringValue = "CopyAttach-\(formatter.string(from: date)).png"
        // The save panel is a modal window of this app: it takes key status
        // from the nonactivating popup, and the popup must survive that focus
        // transfer — it stays behind the panel and remains the session the
        // user returns to. `isPresentingModalPanel` suppresses the resign-key
        // dismissal for exactly this window; key status is handed back after
        // the modal loop ends.
        let popup = popupWindow
        popup?.isPresentingModalPanel = true
        defer { popup?.isPresentingModalPanel = false }

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if let popup, popup.isVisible { popup.makeKey() }
        guard response == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            debugLog("saveImageItem: failed to write \(url.path): \(error)")
        }
    }
}
