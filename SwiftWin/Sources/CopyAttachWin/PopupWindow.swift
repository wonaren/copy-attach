// PopupWindow.swift — borderless popup window: search box + virtual list.
//
// Win32 MVP of the macOS HistoryPopupWindow: a Spotlight-style borderless
// window near the top-center of the work area, a single-line search edit on
// top and an owner-data SysListView32 below (no row copies — the list pulls
// cell text on demand from `displayedRows` via LVN_GETDISPINFO).
//
// Keyboard model (mirrors the macOS keymap):
//   ↑/↓ select · Enter paste · Esc close · Delete delete · Ctrl+Z undo.
// The search edit and the list are subclassed so the keys keep working
// whichever child has focus.

import WinSDK
import CCopyAttach
import Foundation

let popupClassNameW: String = "CopyAttachPopupWindow"

final class PopupController {
    static let shared = PopupController()

    var hwnd: HWND?
    var hwndSearch: HWND?
    var hwndList: HWND?

    /// The window that was foreground before the popup appeared — the paste
    /// target. Ctrl+V must land there, never on our own popup.
    fileprivate var pasteTarget: HWND?
    fileprivate var allRows: [HistoryRow] = []
    fileprivate var displayedRows: [HistoryRow] = []
    fileprivate var selectedRow: Int = -1
    fileprivate var lastRevision: UInt64 = 0
    fileprivate var lastImageCounter: UInt64 = 0

    private let popupWidth: Int32 = 660
    private let popupHeight: Int32 = 520
    private let searchHeight: Int32 = 36

    // MARK: - Creation

    func registerAndCreate(hInstance: HINSTANCE) -> Bool {
        var wc = WNDCLASSW(
            style: UINT(CS_HREDRAW | CS_VREDRAW),
            lpfnWndProc: popupWndProc,
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hInstance,
            hIcon: nil,
            hCursor: loadCursorByID(32512), // IDC_ARROW
            hbrBackground: nil,
            lpszMenuName: nil,
            lpszClassName: popupClassNameW.wide
        )
        guard RegisterClassW(&wc) != 0 else {
            fputs("CopyAttach: RegisterClassW(popup) failed: \(GetLastError())\n", stderr)
            return false
        }

        // Top-center of the primary work area (Spotlight position).
        var work = RECT()
        _ = SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
        let x = work.left + ((work.right - work.left) - popupWidth) / 2
        let y = work.top + 60

        guard let hwnd = CreateWindowExW(
            DWORD(WS_EX_TOOLWINDOW | WS_EX_TOPMOST),
            popupClassNameW.wide, nil,
            DWORD(WS_POPUP | WS_BORDER),
            x, y, popupWidth, popupHeight,
            nil, nil, hInstance, nil
        ) else {
            fputs("CopyAttach: CreateWindowExW(popup) failed: \(GetLastError())\n", stderr)
            return false
        }
        self.hwnd = hwnd
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, Unmanaged.passUnretained(self).toOpaque())

        createChildren(hInstance: hInstance)
        createColumns()
        if let search = hwndSearch {
            _ = SetWindowSubclass(search, searchSubclassProc, 1, Unmanaged.passUnretained(self).toOpaque())
        }
        if let list = hwndList {
            _ = SetWindowSubclass(list, listSubclassProc, 2, Unmanaged.passUnretained(self).toOpaque())
        }
        return true
    }

    private func createChildren(hInstance: HINSTANCE) {
        guard let parent = hwnd else { return }
        hwndSearch = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE),
            "EDIT".wide, nil,
            DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL),
            8, 8, popupWidth - 16, searchHeight,
            parent, nil, hInstance, nil
        )
        hwndList = CreateWindowExW(
            0, "SysListView32".wide, nil,
            DWORD(WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_OWNERDATA | LVS_SHOWSELALWAYS | LVS_NOSORTHEADER),
            8, 8 + searchHeight + 8, popupWidth - 16, popupHeight - searchHeight - 32,
            parent, nil, hInstance, nil
        )
        if let list = hwndList {
            _ = SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE),
                             WPARAM(UInt(LVS_EX_FULLROWSELECT)), LPARAM(Int(LVS_EX_FULLROWSELECT)))
        }
    }

    private func createColumns() {
        guard let list = hwndList else { return }
        let columns: [(String, Int32)] = [("内容", 380), ("来源", 120), ("时间", 100)]
        for (index, column) in columns.enumerated() {
            column.0.withUnsafeBufferPointer { titleBuf in
                var lvc = LVCOLUMNW()
                lvc.mask = UINT(LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM)
                lvc.cx = column.1
                lvc.iSubItem = Int32(index)
                lvc.pszText = UnsafeMutablePointer<WCHAR>(mutating: titleBuf.baseAddress!)
                _ = SendMessageW(list, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: &lvc)))
            }
        }
    }

    // MARK: - Show / hide

    func toggle() {
        if let hwnd = hwnd, IsWindowVisible(hwnd) != 0 {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let hwnd = hwnd else { return }
        pasteTarget = GetForegroundWindow()
        reloadRows()
        _ = ShowWindow(hwnd, SW_SHOW)
        _ = SetForegroundWindow(hwnd)
        if let search = hwndSearch { _ = SetFocus(search) }
    }

    func hide() {
        guard let hwnd = hwnd else { return }
        _ = ShowWindow(hwnd, SW_HIDE)
        if let target = pasteTarget, target != hwnd {
            _ = SetForegroundWindow(target)
        }
        pasteTarget = nil
    }

    // MARK: - Data

    /// Re-pull the snapshot when the history revision or the image-encoding
    /// counter moved. Called from the WM_TIMER tick on the message window —
    /// the same revision-polling contract the macOS frontend uses.
    func pollBackend() {
        let rev = RustBackend.historyRevision()
        let counter = RustBackend.imageEncodingCounter()
        guard rev != lastRevision || counter != lastImageCounter else { return }
        reloadRows()
    }

    func reloadRows() {
        lastRevision = RustBackend.historyRevision()
        lastImageCounter = RustBackend.imageEncodingCounter()
        allRows = RustBackend.snapshotRows()
        applySearch()
    }

    func applySearch() {
        guard let hwndList = hwndList else { return }
        let query = searchText()
        if query.isEmpty {
            displayedRows = allRows
        } else {
            let matches = RustBackend.searchIds(query)
            displayedRows = allRows.filter { matches.contains($0.entryId) }
        }
        selectedRow = displayedRows.isEmpty ? -1 : 0
        _ = SendMessageW(hwndList, UINT(LVM_SETITEMCOUNT),
                         WPARAM(displayedRows.count), LPARAM(Int(LVSICF_NOINVALIDATEALL)))
        updateSelection(select: selectedRow)
        _ = InvalidateRect(hwndList, nil, 1)
    }

    private func searchText() -> String {
        guard let hwndSearch = hwndSearch else { return "" }
        let length = Int(GetWindowTextLengthW(hwndSearch))
        guard length > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        _ = GetWindowTextW(hwndSearch, &buffer, Int32(buffer.count))
        return String(utf16CodeUnits: buffer, count: length)
    }

    // MARK: - Actions

    fileprivate func moveSelection(_ delta: Int) {
        guard !displayedRows.isEmpty else { return }
        let next = max(0, min(displayedRows.count - 1, selectedRow + delta))
        updateSelection(select: next)
    }

    private func updateSelection(select index: Int) {
        guard let hwndList = hwndList else { return }
        var lvi = LVITEMW()
        lvi.mask = UINT(LVIF_STATE)
        lvi.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        lvi.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        let anchor = selectedRow >= 0 ? selectedRow : 0
        _ = withUnsafeMutablePointer(to: &lvi) { ptr in
            SendMessageW(hwndList, UINT(LVM_SETITEMSTATE), WPARAM(anchor), LPARAM(Int(bitPattern: ptr)))
        }
        selectedRow = index
        if index >= 0 {
            _ = SendMessageW(hwndList, UINT(LVM_ENSUREVISIBLE), WPARAM(index), LPARAM(0))
        }
    }

    fileprivate var selectedEntryId: UInt64? {
        (0..<displayedRows.count).contains(selectedRow) ? displayedRows[selectedRow].entryId : nil
    }

    fileprivate func pasteSelected() {
        guard let entryId = selectedEntryId else { return }
        // Move the captured target back to the foreground so Rust's SendInput
        // Ctrl+V lands in the app the user copied from — never our own popup.
        if let target = pasteTarget, target != hwnd {
            _ = SetForegroundWindow(target)
            Sleep(30)
        }
        if RustBackend.paste(entryId: entryId) {
            hide()
        } else {
            MessageBeep(UINT(MB_ICONERROR))
        }
    }

    fileprivate func deleteSelected() {
        guard let entryId = selectedEntryId else { return }
        _ = RustBackend.delete(entryId: entryId)
        reloadRows()
    }

    fileprivate func undoDelete() {
        guard RustBackend.canUndo() else { return }
        _ = RustBackend.undoDelete()
        reloadRows()
    }
}

// MARK: - Window procedures

private func isCtrlDown() -> Bool {
    (GetKeyState(Int32(VK_CONTROL)) & Int16(0x8000)) != 0
}

private let popupWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    if msg == UINT(WM_COMMAND) {
        // EN_CHANGE from the search edit (controls have no HMENU id; identify
        // by source window).
        if Int((wParam >> 16) & 0xffff) == Int(EN_CHANGE),
           let search = PopupController.shared.hwndSearch,
           HWND(bitPattern: lParam) == search {
            PopupController.shared.applySearch()
        }
    } else if msg == UINT(WM_NOTIFY),
              let nm = UnsafeRawPointer(bitPattern: lParam)?
                  .assumingMemoryBound(to: NMLVDISPINFOW.self),
              nm.pointee.hdr.hwndFrom == PopupController.shared.hwndList,
              nm.pointee.hdr.code == LVN_GETDISPINFOW_VALUE {
        supplyDisplayText(nm, controller: PopupController.shared)
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

private let searchSubclassProc: SUBCLASSPROC = { hwnd, msg, wParam, lParam, _, refData in
    guard msg == UINT(WM_KEYDOWN),
          let refPtr = UnsafeRawPointer(bitPattern: Int(refData)) else {
        return DefSubclassProc(hwnd, msg, wParam, lParam)
    }
    let controller: PopupController = Unmanaged.fromOpaque(refPtr).takeUnretainedValue()
    switch Int32(wParam) {
    case VK_RETURN: controller.pasteSelected(); return 0
    case VK_ESCAPE: controller.hide(); return 0
    case VK_UP: controller.moveSelection(-1); return 0
    case VK_DOWN: controller.moveSelection(1); return 0
    case VK_PRIOR: controller.moveSelection(-10); return 0
    case VK_NEXT: controller.moveSelection(10); return 0
    case VK_DELETE where !isCtrlDown(): controller.deleteSelected(); return 0
    case Int32(0x5A) where isCtrlDown(): controller.undoDelete(); return 0 // 'Z'
    default: break
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam)
}

private let listSubclassProc: SUBCLASSPROC = { hwnd, msg, wParam, lParam, _, _ in
    if msg == UINT(WM_KEYDOWN) {
        let controller = PopupController.shared
        switch Int32(wParam) {
        case VK_RETURN: controller.pasteSelected(); return 0
        case VK_ESCAPE: controller.hide(); return 0
        case Int32(0x5A) where isCtrlDown(): controller.undoDelete(); return 0 // 'Z'
        default: break
        }
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam)
}

/// LVN_GETDISPINFO: hand the requested cell text to the virtual list.
private func supplyDisplayText(_ info: UnsafeMutablePointer<NMLVDISPINFOW>, controller: PopupController) {
    let item = info.pointee.item
    guard item.mask & UINT(LVIF_TEXT) != 0,
          item.pszText != nil, item.cchTextMax > 0 else { return }
    let row = Int(item.iItem)
    guard (0..<controller.displayedRows.count).contains(row) else { return }

    let entry = controller.displayedRows[row]
    let value: String
    switch Int(item.iSubItem) {
    case 0: value = entry.label.isEmpty ? entry.preview : entry.label
    case 1: value = entry.sourceName
    case 2: value = formatTimestamp(entry.timestamp)
    default: return
    }
    copyWideString(value, into: item.pszText!, capacity: Int(item.cchTextMax))
}

private func formatTimestamp(_ timestamp: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else {
        formatter.dateFormat = "MM-dd HH:mm"
    }
    return formatter.string(from: date)
}
