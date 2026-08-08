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
            self.copyItemContent(item)
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
            self.backend.toggleFavorite(item.id)
            // Favorites may shrink displayItems; keep the selection valid.
            if self.selectedIndex > self.maxIndex {
                self.selectedIndex = max(0, self.maxIndex)
            }
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
    /// The monitor re-captures it as a normal clipboard write: dedup keeps the
    /// same entry id and moves it to the top of history (natural "re-copy"
    /// semantics).
    private func copyItemContent(_ item: ClipboardItem) {
        switch item {
        case .text:
            guard let full = item.fullText else {
                debugLog("copyItemContent: failed to load full text for entry \(item.id)")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(full, forType: .string)
        case .image:
            guard let data = item.imageData else {
                debugLog("copyItemContent: image not ready (entry \(item.id))")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
    }

    /// Save an image entry to a user-chosen location as a PNG file.
    private func saveImageItem(_ item: ClipboardItem) {
        guard case .image(_, _, _, _, let timestamp, _, _, _) = item,
              let data = item.imageData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        panel.nameFieldStringValue = "CopyAttach-\(formatter.string(from: date)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            debugLog("saveImageItem: failed to write \(url.path): \(error)")
        }
    }
}
