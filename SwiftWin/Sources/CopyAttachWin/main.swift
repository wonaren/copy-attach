// main.swift — CopyAttach Windows entry point.
//
// A hidden message window owns the tray icon, the global hotkey, and the
// revision-poll timer (the Rust monitor thread runs inside the cdylib and
// does the actual clipboard capture). The popup lives in PopupWindow.swift.

import WinSDK
import CCopyAttach
import Foundation

let messageClassNameW: String = "CopyAttachMessageWindow"
let trayCallbackMessage: UINT = UINT(WM_APP) + 1
let trayIconID: UINT = 1
let hotkeyID: Int32 = 1
let pollTimerID: UInt = 1

final class AppController {
    static let shared = AppController()

    var hwnd: HWND?
    private var trayAdded = false
    private var settings: AppSettings = AppSettings()

    func registerAndCreate(hInstance: HINSTANCE, settings: AppSettings) -> Bool {
        self.settings = settings
        var wc = WNDCLASSW(
            style: 0,
            lpfnWndProc: messageWndProc,
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hInstance,
            hIcon: loadIconByID(32512), // IDI_APPLICATION
            hCursor: nil,
            hbrBackground: nil,
            lpszMenuName: nil,
            lpszClassName: messageClassNameW.wide
        )
        guard RegisterClassW(&wc) != 0 else {
            fputs("CopyAttach: RegisterClassW(message) failed: \(GetLastError())\n", stderr)
            return false
        }
        guard let hwnd = CreateWindowExW(
            0, messageClassNameW.wide, "CopyAttach".wide,
            0, 0, 0, 0, 0,
            nil, nil, hInstance, nil
        ) else {
            fputs("CopyAttach: CreateWindowExW(message) failed: \(GetLastError())\n", stderr)
            return false
        }
        self.hwnd = hwnd
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, Unmanaged.passUnretained(self).toOpaque())

        addTrayIcon()
        addClipboardListener()
        addHotkey()
        // History revision poll — mirrors the macOS frontend's snapshot poll.
        _ = SetTimer(hwnd, pollTimerID, 500, nil)
        return true
    }

    private func addTrayIcon() {
        guard let hwnd = hwnd else { return }
        var nid = NOTIFYICONDATAW()
        nid.cbSize = UINT32(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = trayIconID
        nid.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        nid.uCallbackMessage = trayCallbackMessage
        nid.hIcon = loadIconByID(32512) // IDI_APPLICATION
        fillWideTupleField(&nid.szTip, "CopyAttach — 剪贴板历史", capacity: 128)
        if Shell_NotifyIconW(NIM_ADD, &nid) != 0 {
            trayAdded = true
        } else {
            fputs("CopyAttach: Shell_NotifyIconW failed: \(GetLastError())\n", stderr)
        }
    }

    private func addClipboardListener() {
        guard let hwnd = hwnd else { return }
        // Event-driven clipboard notification; the revision poll stays as the
        // authoritative refresh signal (image Phase 2 encoding moves the
        // counter later than the clipboard write).
        _ = AddClipboardFormatListener(hwnd)
    }

    private func addHotkey() {
        guard let hwnd = hwnd else { return }
        guard RegisterHotKey(hwnd, hotkeyID, UINT(settings.hotkeyMods | UInt32(MOD_NOREPEAT)), settings.hotkeyVK) else {
            fputs("CopyAttach: RegisterHotKey failed (Alt+X may be taken): \(GetLastError())\n", stderr)
            return
        }
    }

    private func showTrayMenu() {
        guard let hwnd = hwnd else { return }
        guard let menu = CreatePopupMenu() else { return }
        _ = AppendMenuW(menu, UINT(MF_STRING), UInt(PopupController.cmdOpen), "打开历史\tAlt+X".wide)
        _ = AppendMenuW(menu, UINT(MF_STRING), UInt(PopupController.cmdClearHistory), "清除历史".wide)
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        _ = AppendMenuW(menu, UINT(MF_STRING), UInt(PopupController.cmdExit), "退出".wide)

        var pt = POINT()
        _ = GetCursorPos(&pt)
        _ = SetForegroundWindow(hwnd) // required so the menu dismisses on outside click
        let cmd = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY), pt.x, pt.y, 0, hwnd, nil)
        DestroyMenu(menu)

        switch Int(cmd) {
        case PopupController.cmdOpen:
            PopupController.shared.show()
        case PopupController.cmdClearHistory:
            RustBackend.clearHistory()
            PopupController.shared.reloadRows()
        case PopupController.cmdExit:
            DestroyWindow(hwnd)
        default:
            break
        }
    }

    func run() {
        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) > 0 {
            _ = TranslateMessage(&msg)
            _ = DispatchMessageW(&msg)
        }
        if trayAdded, let hwnd = hwnd {
            var nid = NOTIFYICONDATAW()
            nid.cbSize = UINT32(MemoryLayout<NOTIFYICONDATAW>.size)
            nid.hWnd = hwnd
            nid.uID = trayIconID
            _ = Shell_NotifyIconW(NIM_DELETE, &nid)
        }
        _ = UnregisterHotKey(hwnd, hotkeyID)
    }
}

// Tray context-menu command ids.
let cmdOpen: Int = 2001
let cmdClearHistory: Int = 2002
let cmdExit: Int = 2003

private let messageWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch msg {
    case UINT(WM_HOTKEY):
        if Int32(wParam) == hotkeyID {
            PopupController.shared.toggle()
        }
    case trayCallbackMessage:
        // Tray icon mouse activity (NIF_MESSAGE callback).
        if lParam == Int(WM_LBUTTONDBLCLK) || lParam == Int(WM_LBUTTONUP) {
            PopupController.shared.show()
        } else if lParam == Int(WM_RBUTTONUP) || lParam == Int(WM_CONTEXTMENU) {
            AppController.shared.showTrayMenu()
        }
    case UINT(WM_TIMER):
        if wParam == WPARAM(pollTimerID) {
            PopupController.shared.pollBackend()
        }
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        break
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

// ─── Startup ───

let settings = AppSettings.load()
guard RustBackend.start(debugLogging: settings.debugLogging) else {
    exit(1)
}
RustBackend.setCleanupThreshold(settings.cleanupThreshold)

let hInstance = GetModuleHandleW(nil)
guard AppController.shared.registerAndCreate(hInstance: hInstance, settings: settings),
      PopupController.shared.registerAndCreate(hInstance: hInstance) else {
    RustBackend.shutdown()
    exit(1)
}

AppController.shared.run()
RustBackend.shutdown()

