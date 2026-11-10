import AppKit
import SwiftUI

struct NativeHistoryListTheme {
    let primaryText: NSColor
    let secondaryText: NSColor
    let mutedText: NSColor
    let rowHover: NSColor
    let rowBorder: NSColor
    let selectedFill: NSColor
    let deleteFill: NSColor
    let accent: NSColor
    let tagAccent: NSColor
    let searchHighlightBackground: NSColor
    let searchHighlightText: NSColor
}

struct NativeDragPayload {
    let data: [String: Data]
    let chipItem: ClipboardItem
    let chipCount: Int
}

struct NativeHistoryListRow: Equatable {
    enum Kind: Equatable {
        case separator
        case item
    }

    let id: Int
    let kind: Kind
    let timestamp: UInt64
    let itemIndex: Int
    let item: ClipboardItem?
    let isFavorite: Bool
    let quickSlot: Int?
    let queueOrder: Int?
    let shortcutHint: String?
    var isEditing = false

    var contentHeight: CGFloat {
        switch kind {
        case .separator:
            return NativeListMetrics.separatorContentHeight
        case .item:
            guard let item else { return NativeListMetrics.textContentHeight }
            return item.isText || item.hasCustomLabel || isEditing
                ? NativeListMetrics.textContentHeight
                : NativeListMetrics.imageContentHeight
        }
    }

    var rowHeight: CGFloat {
        contentHeight + NativeListMetrics.rowSpacing
    }
}

enum NativeListMetrics {
    static let separatorContentHeight: CGFloat = 22
    static let textContentHeight: CGFloat = 26
    static let imageContentHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 3
    static let horizontalInset: CGFloat = 2
    static let contentLeading: CGFloat = 4
    static let headerHeight: CGFloat = 22
    static let headerTop: CGFloat = 2
    static let topHoleHeight: CGFloat = headerTop + headerHeight

    static func rowHeight(for row: NativeHistoryListRow) -> CGFloat {
        row.rowHeight
    }
}

struct NativeHistoryListView: NSViewRepresentable {
    let rows: [NativeHistoryListRow]
    let structureToken: Int
    let visualToken: Int
    let theme: NativeHistoryListTheme
    let selectedItemId: Int?
    let editingItemID: Int?
    @Binding var editingText: String
    let resetToken: Int
    let scrollTarget: Int?
    let isDeleteModifierPressed: Bool
    let isCommandPressed: Bool
    let canToggleQueue: Bool
    let searchQuery: String
    let onActivate: (Int, ClipboardItem) -> Void
    let onToggleQueue: (ClipboardItem) -> Void
    let onHoverChange: (ClipboardItem, Bool, NSRect, Bool) -> Void
    let onContextMenu: (ClipboardItem, NSPoint) -> Void
    let onCommitRemark: (Int, String) -> Void
    let onCancelRemark: () -> Void
    let onDragPayload: (ClipboardItem) -> NativeDragPayload
    let reportsSelectedRowFrame: Bool
    let onSelectedRowFrame: (CGRect?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NativeHistoryListContainerView {
        let view = NativeHistoryListContainerView()
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NativeHistoryListContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeHistoryListView
        private(set) var rows: [NativeHistoryListRow] = []
        private weak var container: NativeHistoryListContainerView?
        private weak var tableView: NSTableView?
        private var lastStructureToken: Int?
        private var lastVisualToken: Int?
        private var lastSelectedItemId: Int?
        private var lastEditingItemID: Int?
        private var lastReportedSelectedRowFrame: CGRect?
        private var lastResetToken: Int?
        private var lastScrollTarget: Int?
        private var lastSearchQuery = ""
        private var lastDeleteModifierPressed = false
        private var lastCanToggleQueue = false
        private var rowIndexByID: [Int: Int] = [:]
        private var rowIndexByItemID: [Int: Int] = [:]
        private(set) var hoveredRow: Int?

        init(_ parent: NativeHistoryListView) {
            self.parent = parent
        }

        func attach(to container: NativeHistoryListContainerView) {
            self.container = container
            self.tableView = container.tableView
            container.tableView.delegate = self
            container.tableView.dataSource = self
            container.tableView.nativeCoordinator = self
        }

        func refresh() {
            guard let container, tableView != nil else { return }
            let structureChanged = lastStructureToken != parent.structureToken
            let visualChanged = lastVisualToken != parent.visualToken
            let editingChanged = lastEditingItemID != parent.editingItemID
            let deferChanges = lastEditingItemID != nil && parent.editingItemID != nil
            let previousSelectedItemId = lastSelectedItemId
            let previousEditingItemID = lastEditingItemID
            let selectedChanged = previousSelectedItemId != parent.selectedItemId
            let resetChanged = lastResetToken != parent.resetToken
            let searchQueryChanged = lastSearchQuery != parent.searchQuery
            let scrollTargetChanged = lastScrollTarget != parent.scrollTarget
            let deleteChanged = lastDeleteModifierPressed != parent.isDeleteModifierPressed
            let canToggleChanged = lastCanToggleQueue != parent.canToggleQueue

            lastSelectedItemId = parent.selectedItemId
            lastEditingItemID = parent.editingItemID
            lastResetToken = parent.resetToken
            lastScrollTarget = parent.scrollTarget
            lastSearchQuery = parent.searchQuery
            lastDeleteModifierPressed = parent.isDeleteModifierPressed
            lastCanToggleQueue = parent.canToggleQueue

            var anchor: ScrollAnchor?
            var appliedStructure = false
            if structureChanged && !deferChanges {
                if let hoveredRow, let old = item(forRow: hoveredRow) {
                    parent.onHoverChange(old, false, .zero, false)
                }
                anchor = currentScrollAnchor()
                rows = parent.rows
                rebuildMaps()
                container.reloadRows()
                hoveredRow = nil
                appliedStructure = true
                lastStructureToken = parent.structureToken
            } else if !structureChanged && visualChanged && !deferChanges {
                rows = parent.rows
                rebuildMaps()
                container.reloadVisibleRows()
                lastVisualToken = parent.visualToken
            }
            if editingChanged && !appliedStructure {
                rows = parent.rows
                rebuildMaps()
                for itemID in [previousEditingItemID, parent.editingItemID].compactMap({ $0 }) {
                    reload(row: rowIndexByItemID[itemID])
                    noteHeight(row: rowIndexByItemID[itemID])
                }
            }
            if resetChanged || searchQueryChanged || (scrollTargetChanged && parent.scrollTarget == 0) {
                container.scrollToTop()
            } else if appliedStructure {
                if !restoreScrollAnchor(anchor), selectedChanged,
                   let selectedItemId = parent.selectedItemId,
                   let row = rowIndexByItemID[selectedItemId] {
                    container.scrollToRow(row)
                }
            } else if selectedChanged && !deferChanges {
                if let selectedItemId = parent.selectedItemId,
                   let row = rowIndexByItemID[selectedItemId] {
                    container.scrollToRow(row)
                }
            }
            if !appliedStructure && !deferChanges {
                if selectedChanged {
                    if let previousSelectedItemId, let row = rowIndexByItemID[previousSelectedItemId] {
                        reload(row: row)
                    }
                    if let selectedItemId = parent.selectedItemId, let row = rowIndexByItemID[selectedItemId] {
                        reload(row: row)
                    }
                }
                if deleteChanged, let selectedItemId = parent.selectedItemId,
                   let row = rowIndexByItemID[selectedItemId] {
                    reload(row: row)
                }
                if canToggleChanged {
                    container.reloadVisibleRows()
                }
            }
            container.updateHeader()
            reportSelectedRowFrame()
        }

        func reportSelectedRowFrame() {
            guard parent.reportsSelectedRowFrame else { return }
            let frame = selectedRowFrame()
            guard frame != lastReportedSelectedRowFrame else { return }
            lastReportedSelectedRowFrame = frame
            parent.onSelectedRowFrame(frame)
        }

        private func selectedRowFrame() -> CGRect? {
            guard let tableView, let window = tableView.window, let contentView = window.contentView,
                  let selectedItemId = parent.selectedItemId,
                  let row = rowIndexByItemID[selectedItemId] else { return nil }
            let rowRect = tableView.rect(ofRow: row)
            let contentRect = NSRect(x: rowRect.minX + NativeListMetrics.horizontalInset,
                                     y: rowRect.minY,
                                     width: max(rowRect.width - NativeListMetrics.horizontalInset * 2, 1),
                                     height: rows[row].contentHeight)
            guard contentRect.intersects(tableView.visibleRect) else { return nil }
            let windowRect = tableView.convert(contentRect, to: nil)
            return contentView.convert(windowRect, from: nil)
        }

        private struct ScrollAnchor {
            let rowID: Int
            let rowOffset: CGFloat
            let atTop: Bool
        }

        private func currentScrollAnchor() -> ScrollAnchor? {
            guard let tableView, let container, !rows.isEmpty else { return nil }
            let visible = tableView.visibleRect
            let row = tableView.row(at: NSPoint(x: 1, y: visible.minY + 1))
            guard row >= 0, row < rows.count else { return nil }
            let rowRect = tableView.rect(ofRow: row)
            return ScrollAnchor(rowID: rows[row].id,
                                rowOffset: visible.minY - rowRect.minY,
                                atTop: visible.minY <= -1)
        }

        private func restoreScrollAnchor(_ anchor: ScrollAnchor?) -> Bool {
            guard let anchor, let container else { return false }
            if anchor.atTop {
                container.scrollToTop()
                return true
            }
            guard let row = rowIndexByID[anchor.rowID] else { return false }
            let clip = container.scrollView.contentView
            let y = container.tableView.rect(ofRow: row).minY + anchor.rowOffset
            clip.scroll(to: NSPoint(x: 0, y: y))
            container.scrollView.reflectScrolledClipView(clip)
            container.updateHeader()
            return true
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < rows.count else { return 0 }
            return rows[row].rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rows.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("NativeHistoryRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeHistoryRowView
                ?? NativeHistoryRowView()
            view.identifier = identifier
            view.configure(configuration: configuration(forRow: row))
            return view
        }

        func configuration(forRow row: Int) -> NativeHistoryRowConfiguration {
            let model = rows[row]
            return NativeHistoryRowConfiguration(
                row: model,
                theme: parent.theme,
                isSelected: model.kind == .item && model.id == parent.selectedItemId,
                isHovered: row == hoveredRow,
                isDeleteModifierPressed: parent.isDeleteModifierPressed,
                isCommandPressed: parent.isCommandPressed,
                canToggleQueue: parent.canToggleQueue,
                searchQuery: parent.searchQuery,
                isEditing: model.kind == .item && model.id == parent.editingItemID,
                editingText: parent.$editingText,
                onCommitRemark: { text in self.parent.onCommitRemark(model.id, text) },
                onCancelRemark: parent.onCancelRemark,
                onActivate: { [weak self] in
                    guard let item = model.item else { return }
                    self?.parent.onActivate(model.itemIndex, item)
                },
                onToggleQueue: { [weak self] in
                    guard let item = model.item else { return }
                    self?.parent.onToggleQueue(item)
                }
            )
        }

        func itemRowIndex(forItemID itemID: Int) -> Int? {
            rowIndexByItemID[itemID]
        }

        struct PendingClick {
            let row: Int
            let item: ClipboardItem
            let itemIndex: Int
            let togglesQueue: Bool
        }

        func clickTarget(row: Int, point: NSPoint) -> PendingClick? {
            guard let container, let tableView, row >= 0, row < rows.count else { return nil }
            guard point.y >= tableView.visibleRect.minY + container.topHoleHeight else { return nil }
            let model = rows[row]
            guard model.kind == .item, let item = model.item else { return nil }
            var togglesQueue = false
            if let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeHistoryRowView {
                let local = rowView.convert(point, from: tableView)
                togglesQueue = rowView.queueToggleRect.insetBy(dx: -2, dy: -2).contains(local)
            }
            return PendingClick(row: row, item: item, itemIndex: model.itemIndex, togglesQueue: togglesQueue)
        }

        func presentContextMenu(item: ClipboardItem, windowPoint: NSPoint) {
            parent.onContextMenu(item, windowPoint)
        }

        func dragPayload(for item: ClipboardItem) -> NativeDragPayload {
            parent.onDragPayload(item)
        }

        func performClick(_ click: PendingClick) {
            if click.togglesQueue {
                parent.onToggleQueue(click.item)
                reload(row: click.row)
            } else {
                parent.onActivate(click.itemIndex, click.item)
            }
        }

        func updateHover(row: Int?, moved: Bool) {
            if row == hoveredRow { return }
            let old = hoveredRow
            hoveredRow = row
            if let old, let item = item(forRow: old) {
                parent.onHoverChange(item, false, screenRect(forRow: old), false)
                reload(row: old)
            }
            if let row, let item = item(forRow: row) {
                parent.onHoverChange(item, true, screenRect(forRow: row), moved)
                reload(row: row)
            }
        }

        func item(forRow row: Int) -> ClipboardItem? {
            guard row >= 0, row < rows.count, rows[row].kind == .item else { return nil }
            return rows[row].item
        }

        func screenRect(forRow row: Int) -> NSRect {
            guard let tableView, let window = tableView.window, row >= 0, row < rows.count else { return .zero }
            let rowRect = tableView.rect(ofRow: row)
            let contentRect = NSRect(x: rowRect.minX + NativeListMetrics.horizontalInset,
                                     y: rowRect.minY,
                                     width: max(rowRect.width - NativeListMetrics.horizontalInset * 2, 1),
                                     height: rows[row].contentHeight)
            let windowRect = tableView.convert(contentRect, to: nil)
            return window.convertToScreen(windowRect)
        }

        func reload(row: Int?) {
            guard let tableView, let row, row >= 0, row < rows.count else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }

        private func noteHeight(row: Int?) {
            guard let tableView, let row, row >= 0, row < rows.count else { return }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }

        private func rebuildMaps() {
            rowIndexByID.removeAll(keepingCapacity: true)
            rowIndexByItemID.removeAll(keepingCapacity: true)
            rowIndexByID.reserveCapacity(rows.count)
            rowIndexByItemID.reserveCapacity(rows.count)
            for (index, row) in rows.enumerated() {
                rowIndexByID[row.id] = index
                if row.kind == .item, let item = row.item {
                    rowIndexByItemID[item.id] = index
                }
            }
        }
    }
}

final class NativeHistoryListContainerView: NSView {
    weak var coordinator: NativeHistoryListView.Coordinator?
    let scrollView = NSScrollView()
    let tableView = NativeHistoryTableView()
    let headerView = NativeHistoryHeaderView()
    private let maskLayer = CAShapeLayer()
    private var boundsObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private var lastMousePoint: NSPoint?
    private var hasHeaders = true
    private var lastAppearanceName: NSAppearance.Name?

    var topHoleHeight: CGFloat { hasHeaders ? NativeListMetrics.topHoleHeight : 0 }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NativeHistoryColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        headerView.hitTestEnabled = false
        addSubview(scrollView)
        addSubview(headerView)

        scrollView.wantsLayer = true
        maskLayer.fillRule = .evenOdd
        scrollView.layer?.mask = maskLayer

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.boundsChanged()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = max(scrollView.contentSize.width, 1)
        if abs(tableView.frame.width - width) > 0.5 {
            tableView.setFrameSize(NSSize(width: width, height: tableView.frame.height))
        }
        if let column = tableView.tableColumns.first, abs(column.width - tableView.bounds.width) > 0.5 {
            column.width = tableView.bounds.width
        }
        headerView.frame = NSRect(x: NativeListMetrics.contentLeading,
                                  y: NativeListMetrics.headerTop,
                                  width: max(bounds.width - NativeListMetrics.contentLeading * 2, 1),
                                  height: NativeListMetrics.headerHeight)
        updateMask()
        updateHeader()
        coordinator?.reportSelectedRowFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let name = effectiveAppearance.name
        guard let lastAppearanceName else {
            self.lastAppearanceName = name
            return
        }
        guard name != lastAppearanceName else { return }
        self.lastAppearanceName = name
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
            self?.headerView.needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let moved = lastMousePoint.map { hypot(point.x - $0.x, point.y - $0.y) > 1 } ?? true
        lastMousePoint = point
        updateHover(at: point, moved: moved)
    }

    override func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        coordinator?.updateHover(row: nil, moved: false)
    }

    func reloadRows() {
        guard let coordinator else { return }
        let totalHeight = coordinator.rows.reduce(CGFloat(0)) { $0 + $1.rowHeight }
        let width = max(scrollView.contentSize.width, 1)
        tableView.setFrameSize(NSSize(width: width, height: totalHeight))
        tableView.reloadData()
        hasHeaders = coordinator.rows.first?.kind == .separator
        headerView.isHidden = !hasHeaders
        updateMask()
        if headerView.timestamp == nil, let first = coordinator.rows.first {
            headerView.theme = coordinator.parent.theme
            headerView.timestamp = first.timestamp
            headerView.needsDisplay = true
        }
        updateHeader()
        DispatchQueue.main.async { [weak self] in
            self?.updateHeader()
        }
    }

    func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integer: 0))
    }

    func scrollToTop() {
        tableView.scrollRowToVisible(0)
        if let clip = scrollView.contentView as NSClipView? {
            clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func scrollToRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(row)
        let rowRect = tableView.rect(ofRow: row)
        let visible = tableView.visibleRect
        let topLimit = visible.minY + topHoleHeight
        if rowRect.minY < topLimit {
            let delta = topLimit - rowRect.minY
            let clip = scrollView.contentView
            let target = NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y - delta)
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
        updateHeader()
    }

    func updateHeader() {
        guard let coordinator, hasHeaders else {
            headerView.timestamp = nil
            return
        }
        var row = tableView.row(at: NSPoint(x: 1, y: tableView.visibleRect.minY + 1))
        if row < 0, tableView.visibleRect.minY <= 1 {
            row = 0
        }
        let timestamp: UInt64?
        if row >= 0, row < coordinator.rows.count {
            timestamp = coordinator.rows[row].timestamp
        } else {
            timestamp = nil
        }
        if headerView.timestamp != timestamp || headerView.theme == nil {
            headerView.theme = coordinator.parent.theme
            headerView.timestamp = timestamp
            headerView.needsDisplay = true
        }
    }

    private func updateHover(at point: NSPoint, moved: Bool) {
        guard let coordinator else { return }
        let hole = topHoleHeight
        if point.y < hole {
            coordinator.updateHover(row: nil, moved: moved)
            return
        }
        let tablePoint = tableView.convert(point, from: self)
        let row = tableView.row(at: tablePoint)
        coordinator.updateHover(row: row >= 0 ? row : nil, moved: moved)
    }

    private func boundsChanged() {
        updateHeader()
        coordinator?.reportSelectedRowFrame()
    }

    private func updateMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        maskLayer.frame = scrollView.bounds
        let path = CGMutablePath()
        path.addRect(scrollView.bounds)
        let hole = topHoleHeight
        if hole > 0 {
            let y = scrollView.isFlipped ? 0 : scrollView.bounds.height - hole
            path.addRect(CGRect(x: 0, y: y, width: scrollView.bounds.width, height: hole))
        }
        maskLayer.path = path
    }
}

final class NativeHistoryTableView: NSTableView {
    weak var nativeCoordinator: NativeHistoryListView.Coordinator?
    private var pendingClick: NativeHistoryListView.Coordinator.PendingClick?
    private var pressPoint: NSPoint = .zero

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator = nativeCoordinator else { return }
        pressPoint = convert(event.locationInWindow, from: nil)
        pendingClick = coordinator.clickTarget(row: row(at: pressPoint), point: pressPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pending = pendingClick else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 3 else { return }
        pendingClick = nil
        guard let payload = nativeCoordinator?.dragPayload(for: pending.item) else { return }
        let pasteboardItem = NSPasteboardItem()
        for (type, data) in payload.data {
            pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = Self.dragImage(item: payload.chipItem, count: payload.chipCount)
        let frame = NSRect(x: point.x - image.size.width / 2,
                           y: point.y - image.size.height / 2,
                           width: image.size.width,
                           height: image.size.height)
        draggingItem.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private static func dragImage(item: ClipboardItem, count: Int) -> NSImage {
        let hosting = NSHostingView(rootView: AnyView(DragChip(item: item, count: count).withAppTheme()))
        hosting.sizingOptions = []
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 250), height: max(fitting.height, 30))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return NSImage(size: size)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    override func mouseUp(with event: NSEvent) {
        guard let click = pendingClick else { return }
        pendingClick = nil
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 3 { return }
        nativeCoordinator?.performClick(click)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let coordinator = nativeCoordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let click = coordinator.clickTarget(row: row(at: point), point: point) {
            coordinator.presentContextMenu(item: click.item, windowPoint: event.locationInWindow)
        }
    }
}

struct NativeHistoryRowConfiguration {
    let row: NativeHistoryListRow
    let theme: NativeHistoryListTheme
    let isSelected: Bool
    let isHovered: Bool
    let isDeleteModifierPressed: Bool
    let isCommandPressed: Bool
    let canToggleQueue: Bool
    let searchQuery: String
    let isEditing: Bool
    let editingText: Binding<String>
    let onCommitRemark: (String) -> Void
    let onCancelRemark: () -> Void
    let onActivate: () -> Void
    let onToggleQueue: () -> Void
}

final class NativeHistoryRowView: NSTableCellView {
    private var configuration: NativeHistoryRowConfiguration?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailDbId: Int?
    private var thumbnailImage: NSImage?
    private var editorHost: NSHostingView<AnyView>?
    private var editorItemID: Int?
    private(set) var queueToggleRect: NSRect = .zero

    override var isFlipped: Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        guard let configuration, configuration.row.kind == .item else { return .staticText }
        return .button
    }

    override func accessibilityLabel() -> String? {
        guard let configuration else { return nil }
        if configuration.row.kind == .separator {
            let parts = DayGroup.labelParts(for: configuration.row.timestamp)
            return parts.relative.map { "\(parts.date) \($0)" } ?? parts.date
        }
        guard let item = configuration.row.item else { return nil }
        let content: String
        if item.isText {
            content = item.hasCustomLabel ? item.customLabel : item.displayPreview
        } else {
            content = item.hasCustomLabel ? item.customLabel : "图片"
        }
        return item.sourceName.isEmpty ? content : "\(content)，\(item.sourceName)"
    }

    override func accessibilityValue() -> Any? {
        guard let configuration, let item = configuration.row.item else { return nil }
        if item.isText {
            return item.hasCustomLabel ? item.customLabel : item.displayPreview
        }
        return item.hasCustomLabel ? item.customLabel : "图片"
    }

    override func isAccessibilitySelected() -> Bool {
        configuration?.isSelected ?? false
    }

    override func accessibilityPerformPress() -> Bool {
        guard let configuration, configuration.row.kind == .item else { return false }
        configuration.onActivate()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let configuration, configuration.row.kind == .item, configuration.canToggleQueue else {
            return nil
        }
        let title = configuration.row.queueOrder == nil ? "加入粘贴队列" : "移出粘贴队列"
        return [NSAccessibilityCustomAction(name: title) { [weak self] in
            self?.configuration?.onToggleQueue()
            return true
        }]
    }

    func configure(configuration: NativeHistoryRowConfiguration) {
        self.configuration = configuration
        if configuration.row.kind == .item,
           case .image(_, let dbId, _, _, _, _, _, _, _)? = configuration.row.item {
            if thumbnailDbId != dbId {
                thumbnailTask?.cancel()
                thumbnailTask = nil
                thumbnailDbId = dbId
                thumbnailImage = ClipboardBackend.shared.cachedThumbnail(dbId: dbId)
                if thumbnailImage == nil, dbId != 0 {
                    thumbnailTask = Task { @MainActor [weak self] in
                        let box = RowThumbnailBox.current(scale: self?.window?.backingScaleFactor ?? 2)
                        let image = await ClipboardBackend.shared.loadThumbnail(dbId: dbId, box: box)
                        guard !Task.isCancelled, let self, self.thumbnailDbId == dbId else { return }
                        self.thumbnailImage = image
                        self.needsDisplay = true
                    }
                }
            }
        } else {
            thumbnailTask?.cancel()
            thumbnailTask = nil
            thumbnailDbId = nil
            thumbnailImage = nil
        }
        updateEditor(configuration: configuration)
        needsDisplay = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        editorHost?.removeFromSuperview()
        editorHost = nil
        editorItemID = nil
    }

    private func updateEditor(configuration: NativeHistoryRowConfiguration) {
        guard configuration.isEditing, let item = configuration.row.item else {
            editorHost?.removeFromSuperview()
            editorHost = nil
            editorItemID = nil
            return
        }
        let host: NSHostingView<AnyView>
        if let editorHost, editorItemID == item.id {
            host = editorHost
            host.rootView = AnyView(editorContent(configuration: configuration, item: item))
        } else {
            editorHost?.removeFromSuperview()
            host = NSHostingView(rootView: AnyView(editorContent(configuration: configuration, item: item)))
            host.sizingOptions = []
            host.wantsLayer = true
            addSubview(host)
            editorHost = host
            editorItemID = item.id
        }
        host.frame = editorFrame(height: configuration.row.contentHeight)
    }

    private func editorFrame(height: CGFloat) -> NSRect {
        let leading = NativeListMetrics.horizontalInset + 2 + 20 + 2
        return NSRect(x: leading, y: 0, width: max(bounds.width - leading - 120, 120), height: height)
    }

    private func editorContent(configuration: NativeHistoryRowConfiguration, item: ClipboardItem) -> some View {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let textColor = dark ? NSColor.white : NSColor(white: 0.1, alpha: 1)
        let fill = dark ? Color.black.opacity(0.35) : Color.white.opacity(0.95)
        let strokeColor = increased
            ? (dark ? Color.white : Color.black)
            : (dark ? Color.white.opacity(0.45) : Color.black.opacity(0.30))
        let placeholder = item.hasCustomLabel
            ? item.customLabel
            : (item.isText ? "添加备注..." : "添加图片备注...")
        return HStack(spacing: 4) {
            if !item.isText {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .systemOrange))
            }
            InlineRemarkField(
                text: configuration.editingText,
                placeholder: placeholder,
                textColor: textColor,
                onCommit: configuration.onCommitRemark,
                onCancel: configuration.onCancelRemark
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: increased ? 1.5 : 1)
                )
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let configuration else { return }
        let theme = configuration.theme
        let row = configuration.row
        let contentHeight = row.contentHeight
        let contentRect = NSRect(x: NativeListMetrics.horizontalInset,
                                 y: 0,
                                 width: max(bounds.width - NativeListMetrics.horizontalInset * 2, 1),
                                 height: contentHeight)
        drawBackground(in: contentRect, configuration: configuration)
        switch row.kind {
        case .separator:
            drawSeparator(timestamp: row.timestamp, in: contentRect, theme: theme)
        case .item:
            guard let item = row.item else { return }
            drawItem(row: row, item: item, in: contentRect, configuration: configuration)
        }
    }

    private func drawBackground(in rect: NSRect, configuration: NativeHistoryRowConfiguration) {
        let theme = configuration.theme
        if configuration.isSelected {
            let fill = configuration.isDeleteModifierPressed ? theme.deleteFill : theme.selectedFill
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            fill.setFill()
            path.fill()
            let stroke = configuration.isDeleteModifierPressed
                ? NSColor.white.withAlphaComponent(0.85)
                : NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.85)
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if configuration.isHovered {
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            theme.rowHover.setFill()
            path.fill()
        }
    }

    private func drawSeparator(timestamp: UInt64, in rect: NSRect, theme: NativeHistoryListTheme) {
        let parts = DayGroup.labelParts(for: timestamp)
        let text = parts.relative.map { "\(parts.date) \($0)" } ?? parts.date
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.secondaryText
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: rect.minX + 2,
                              y: rect.midY - size.height / 2,
                              width: max(rect.width - 4, 1),
                              height: size.height)
        (text as NSString).draw(in: textRect, withAttributes: attrs)
        let lineY = rect.midY
        let lineStart = textRect.minX + size.width + 6
        theme.rowBorder.setFill()
        NSRect(x: lineStart, y: lineY, width: max(rect.maxX - 2 - lineStart, 0), height: 0.5).fill()
    }

    private func drawItem(row: NativeHistoryListRow, item: ClipboardItem, in rect: NSRect,
                          configuration: NativeHistoryRowConfiguration) {
        let theme = configuration.theme
        let selected = configuration.isSelected
        let primary = selected ? NSColor.white : theme.primaryText
        let secondary = selected ? NSColor.white.withAlphaComponent(0.95) : theme.secondaryText
        let contentY = rect.midY

        let iconRect = NSRect(x: rect.minX + 2, y: contentY - 10, width: 20, height: 20)
        drawAppIcon(item: item, in: iconRect, theme: theme, selected: selected)

        let leading = iconRect.maxX + 2
        let trailing = drawTrailing(row: row, item: item, in: rect, configuration: configuration,
                                    primary: primary, secondary: secondary)
        let mainMaxX = trailing.minX - 4
        let mainWidth = max(mainMaxX - leading, 1)
        let mainRect = NSRect(x: leading, y: rect.minY, width: mainWidth, height: rect.height)
        if configuration.isEditing { return }

        if item.isText {
            let text = item.hasCustomLabel ? item.customLabel : item.displayPreview
            let color = item.hasCustomLabel
                ? (selected ? NSColor.white : theme.tagAccent)
                : primary
            drawContentText(text, font: .systemFont(ofSize: 13), color: color, in: mainRect,
                            configuration: configuration)
        } else if item.hasCustomLabel {
            drawPhotoRemark(item.customLabel, in: mainRect,
                            color: selected ? NSColor.white : theme.tagAccent,
                            configuration: configuration)
        } else {
            drawThumbnail(dbId: imageDbId(item), in: mainRect, theme: theme)
        }
    }

    private func drawAppIcon(item: ClipboardItem, in rect: NSRect, theme: NativeHistoryListTheme, selected: Bool) {
        if !item.sourceBundleId.isEmpty, let image = getAppIcon(for: item.sourceBundleId) {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4.5, yRadius: 4.5)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: rect.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else if let image = NativeSymbols.image("app.fill", size: 12, color: theme.mutedText) {
            let size = NSSize(width: 14, height: 14)
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawTrailing(row: NativeHistoryListRow, item: ClipboardItem, in rect: NSRect,
                              configuration: NativeHistoryRowConfiguration,
                              primary: NSColor, secondary: NSColor) -> NSRect {
        let theme = configuration.theme
        var right = rect.maxX - 2
        var trailingMinX = right
        if configuration.isSelected && configuration.isDeleteModifierPressed {
            if let image = NativeSymbols.image("delete.left.fill", size: 13, color: .white) {
                let imageRect = NSRect(x: right - 16, y: rect.midY - 8, width: 16, height: 16)
                image.draw(in: imageRect, from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
                right -= 20
                trailingMinX = right
            }
        } else if let hint = row.shortcutHint {
            let color = configuration.isSelected ? NSColor.white : theme.accent
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: color
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            let textRect = NSRect(x: right - size.width, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height)
            (hint as NSString).draw(in: textRect, withAttributes: attrs)
            right = textRect.minX - 4
            trailingMinX = right
        } else if !item.sourceName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: secondary
            ]
            let size = (item.sourceName as NSString).size(withAttributes: attrs)
            let maxWidth = max(rect.width * 0.35, 1)
            let width = min(size.width, maxWidth)
            let textRect = NSRect(x: right - width, y: rect.midY - size.height / 2,
                                  width: width, height: size.height)
            (item.sourceName as NSString).draw(in: textRect, withAttributes: attrs)
            right = textRect.minX - 4
            trailingMinX = right
        }

        if configuration.canToggleQueue && (row.queueOrder != nil || configuration.isHovered) {
            let toggleRect = NSRect(x: right - 18, y: rect.midY - 9, width: 18, height: 18)
            queueToggleRect = toggleRect
            drawQueueToggle(row: row, in: toggleRect, theme: theme, selected: configuration.isSelected)
            right = toggleRect.minX - 4
            trailingMinX = right
        } else {
            queueToggleRect = .zero
        }

        var badgeRight = right
        if item.hasCustomLabel {
            badgeRight -= 16
            if let image = NativeSymbols.image("tag.fill", size: 9.5,
                                               color: configuration.isSelected ? NSColor.white : theme.tagAccent) {
                image.draw(in: NSRect(x: badgeRight, y: rect.midY - 7, width: 14, height: 14),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if row.isFavorite {
            badgeRight -= 18
            if let image = NativeSymbols.image("star.fill", size: 10, color: .systemYellow) {
                image.draw(in: NSRect(x: badgeRight, y: rect.midY - 7, width: 14, height: 14),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let slot = row.quickSlot, row.shortcutHint == nil {
            let text = "右⌘\(slot)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: configuration.isSelected ? NSColor.white : theme.accent
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            badgeRight -= size.width + 2
            (text as NSString).draw(in: NSRect(x: badgeRight, y: rect.midY - size.height / 2,
                                               width: size.width, height: size.height),
                                    withAttributes: attrs)
        }
        return NSRect(x: badgeRight, y: rect.minY, width: max(trailingMinX - badgeRight, 0), height: rect.height)
    }

    private func drawQueueToggle(row: NativeHistoryListRow, in rect: NSRect,
                                 theme: NativeHistoryListTheme, selected: Bool) {
        if let order = row.queueOrder {
            let circleRect = rect.insetBy(dx: 1.75, dy: 1.75)
            let circle = NSBezierPath(ovalIn: circleRect)
            (selected ? NSColor.white : theme.accent).setFill()
            circle.fill()
            let text = "\(order)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: selected ? theme.selectedFill : NSColor.white
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(in: NSRect(x: rect.midX - size.width / 2,
                                               y: rect.midY - size.height / 2,
                                               width: size.width, height: size.height),
                                    withAttributes: attrs)
        } else {
            let circleRect = rect.insetBy(dx: 2.25, dy: 2.25)
            let circle = NSBezierPath(ovalIn: circleRect)
            (selected ? NSColor.white.withAlphaComponent(0.18) : theme.accent.withAlphaComponent(0.12)).setFill()
            circle.fill()
            (selected ? NSColor.white : theme.accent).setStroke()
            circle.lineWidth = 1.15
            circle.stroke()
        }
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let drawRect = NSRect(x: rect.minX, y: rect.midY - size.height / 2,
                              width: rect.width, height: size.height)
        (text as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    private func drawPhotoRemark(_ text: String, in rect: NSRect, color: NSColor,
                                 configuration: NativeHistoryRowConfiguration) {
        var leading = rect.minX
        if let image = NativeSymbols.image("photo.fill", size: 11.5, color: color) {
            image.draw(in: NSRect(x: leading, y: rect.midY - 7, width: 14, height: 14),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            leading += 19
        }
        drawContentText(text, font: .systemFont(ofSize: 13), color: color,
                        in: NSRect(x: leading, y: rect.minY, width: max(rect.maxX - leading, 1), height: rect.height),
                        configuration: configuration)
    }

    private func drawContentText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect,
                                 configuration: NativeHistoryRowConfiguration) {
        let attributed = contentAttributedString(text, font: font, color: color, configuration: configuration)
        guard attributed.length > 0 else { return }
        let size = attributed.size()
        let drawRect = NSRect(x: rect.minX, y: rect.midY - size.height / 2,
                              width: rect.width, height: size.height)
        attributed.draw(with: drawRect,
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        context: nil)
    }

    private func contentAttributedString(_ text: String, font: NSFont, color: NSColor,
                                         configuration: NativeHistoryRowConfiguration) -> NSAttributedString {
        let theme = configuration.theme
        let selected = configuration.isSelected
        let query = configuration.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlightBackground = selected
            ? NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 0.90)
            : theme.searchHighlightBackground
        let highlightText = selected ? NSColor(white: 0.30, alpha: 1) : theme.searchHighlightText
        let baseAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let result = NSMutableAttributedString()
        let nsText = text as NSString
        let matches = Self.hexColorRegex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        var lastEnd = 0
        for match in matches {
            if match.range.location > lastEnd {
                let piece = nsText.substring(with: NSRange(location: lastEnd,
                                                           length: match.range.location - lastEnd))
                result.append(highlightedPiece(piece, attributes: baseAttributes, query: query,
                                               background: highlightBackground, textColor: highlightText))
            }
            let code = nsText.substring(with: match.range)
            if let swatch = Self.swatch(for: code) {
                let attachment = NSTextAttachment()
                attachment.image = swatch
                attachment.bounds = NSRect(x: 0, y: -2, width: 10, height: 10)
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttributes(baseAttributes,
                                               range: NSRange(location: 0, length: attachmentString.length))
                result.append(attachmentString)
            }
            result.append(highlightedPiece(code, attributes: baseAttributes, query: query,
                                           background: highlightBackground, textColor: highlightText))
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < nsText.length {
            let piece = nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))
            result.append(highlightedPiece(piece, attributes: baseAttributes, query: query,
                                           background: highlightBackground, textColor: highlightText))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: style,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    private func highlightedPiece(_ piece: String, attributes: [NSAttributedString.Key: Any], query: String,
                                  background: NSColor, textColor: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: piece, attributes: attributes)
        guard !query.isEmpty else { return attributed }
        let nsPiece = piece as NSString
        var searchRange = NSRange(location: 0, length: nsPiece.length)
        while searchRange.length > 0 {
            let found = nsPiece.range(of: query, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            attributed.addAttributes([.backgroundColor: background, .foregroundColor: textColor],
                                     range: found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: nsPiece.length - next)
        }
        return attributed
    }

    private static let hexColorRegex = try? NSRegularExpression(pattern: "#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\b")
    private static let swatchCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private static func swatch(for code: String) -> NSImage? {
        if let cached = swatchCache.object(forKey: code as NSString) { return cached }
        guard let color = parseHexColor(code) else { return nil }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        swatchCache.setObject(image, forKey: code as NSString)
        return image
    }

    private static func parseHexColor(_ hex: String) -> NSColor? {
        var value = hex
        if value.hasPrefix("#") { value = String(value.dropFirst()) }
        guard let number = UInt64(value, radix: 16) else { return nil }
        switch value.count {
        case 3:
            return NSColor(red: CGFloat((number >> 8) & 0xF) / 15.0,
                           green: CGFloat((number >> 4) & 0xF) / 15.0,
                           blue: CGFloat(number & 0xF) / 15.0,
                           alpha: 1)
        case 6:
            return NSColor(red: CGFloat((number >> 16) & 0xFF) / 255.0,
                           green: CGFloat((number >> 8) & 0xFF) / 255.0,
                           blue: CGFloat(number & 0xFF) / 255.0,
                           alpha: 1)
        default:
            return nil
        }
    }

    private func imageDbId(_ item: ClipboardItem) -> Int {
        if case .image(_, let dbId, _, _, _, _, _, _, _) = item { return dbId }
        return 0
    }

    private func drawThumbnail(dbId: Int, in rect: NSRect, theme: NativeHistoryListTheme) {
        if let image = thumbnailImage ?? ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
            thumbnailImage = image
            let maxHeight: CGFloat = 46
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            let height = maxHeight
            let width = min(maxHeight * aspect, max(rect.width - 2, 1))
            let imageRect = NSRect(x: rect.minX, y: rect.midY - height / 2, width: width, height: height)
            let clip = NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            image.draw(in: imageRect, from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            theme.rowBorder.setStroke()
            clip.lineWidth = 0.5
            clip.stroke()
        } else {
            let placeholder = NSRect(x: rect.minX, y: rect.midY - 23, width: min(140, rect.width), height: 46)
            let path = NSBezierPath(roundedRect: placeholder, xRadius: 6, yRadius: 6)
            theme.rowHover.setFill()
            path.fill()
            let text = dbId == 0 ? "图片编码中…" : "载入预览中…"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: theme.mutedText
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(in: NSRect(x: placeholder.midX - size.width / 2,
                                               y: placeholder.midY - size.height / 2,
                                               width: size.width, height: size.height),
                                    withAttributes: attrs)
        }
    }
}

final class NativeHistoryHeaderView: NSView {
    var timestamp: UInt64?
    var theme: NativeHistoryListTheme?
    var hitTestEnabled = true

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestEnabled ? super.hitTest(point) : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let timestamp, let theme else { return }
        let parts = DayGroup.labelParts(for: timestamp)
        let text = parts.relative.map { "\(parts.date) \($0)" } ?? parts.date
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: theme.secondaryText
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: 0, y: bounds.midY - size.height / 2,
                              width: max(bounds.width, 1), height: size.height)
        (text as NSString).draw(in: textRect, withAttributes: attrs)
        let lineStart = size.width + 6
        theme.rowBorder.setFill()
        NSRect(x: lineStart, y: bounds.midY, width: max(bounds.width - lineStart, 0), height: 0.5).fill()
    }
}

@MainActor
enum NativeSymbols {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(color.description)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = base.withSymbolConfiguration(configuration) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
