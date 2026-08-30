// Win32Helpers.swift — small bridging utilities for the raw Win32 layer.

import WinSDK
import Foundation

extension String {
    /// UTF-16 array suitable for Swift's implicit array-to-LPCWSTR conversion
    /// in C function calls (valid for the duration of the call).
    var wide: [WCHAR] {
        Array(utf16) + [0]
    }
}

/// MAKEINTRESOURCEW replacement: the SDK macros are not imported into Swift.
func intResourceW(_ id: Int) -> LPCWSTR? {
    LPCWSTR(bitPattern: id)
}

/// IDC_ARROW (32512), IDC_IBEAM (32513) etc.
func loadCursorByID(_ id: Int) -> HCURSOR? {
    LoadCursorW(nil, intResourceW(id))
}

/// IDI_APPLICATION (32512) etc.
func loadIconByID(_ id: Int) -> HICON? {
    LoadIconW(nil, intResourceW(id))
}

/// LVN_GETDISPINFOW == LVN_FIRST - 77 (simple-macro arithmetic the SDK
/// importer does not evaluate; hard-coded with a tripwire comment).
let LVN_GETDISPINFOW_VALUE: UINT = UINT(UInt32(bitPattern: Int32(-177)))

/// Copy a Swift string into a null-terminated UTF-16 buffer received from
/// Win32 (e.g. NMLVDISPINFOW.item.pszText during LVN_GETDISPINFO).
func copyWideString(_ value: String, into dst: UnsafeMutablePointer<WCHAR>, capacity: Int) {
    guard capacity > 0 else { return }
    var chars = Array(value.utf16.prefix(capacity - 1))
    chars.append(0)
    chars.withUnsafeBufferPointer { src in
        memcpy(dst, src.baseAddress!, src.count * MemoryLayout<WCHAR>.size)
    }
}

/// Overwrite a fixed-size WCHAR tuple field (e.g. NOTIFYICONDATAW.szTip).
func fillWideTupleField<T>(_ field: inout T, _ value: String, capacity: Int) {
    withUnsafeMutablePointer(to: &field) { ptr in
        let raw = UnsafeMutableRawPointer(ptr)
        var chars = Array(value.utf16.prefix(capacity - 1))
        chars.append(0)
        chars.withUnsafeBufferPointer { src in
            memcpy(raw, src.baseAddress!, src.count * MemoryLayout<WCHAR>.size)
        }
    }
}
