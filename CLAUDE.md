# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build everything (Rust lib + Swift app bundle)
./build.sh

# Rust-only: build release
cargo build --release

# Rust-only: run tests
cargo test

# Open the app
open "CopyAttach.app"
```

The project root for all commands is `clipboard-manager/`. The build script compiles Rust to `target/release/libcopy_attach.dylib`, copies it into `CopyAttach.app/Contents/Frameworks/`, compiles Swift sources with `swiftc`, ad-hoc codesigns, and produces `CopyAttach.app`.

## Architecture

**Rust backend** (`src/lib.rs`) — a `cdylib` that exposes a flat C FFI. It polls the macOS clipboard every 300ms via `arboard`, captures both text and PNG-encoded images, deduplicates (by text equality or image hash), and maintains a history of up to 1000 entries. It also handles paste simulation via `CGEventPost` (Cmd+V) and Accessibility permission checks via `AXIsProcessTrusted`. All state lives in a `OnceLock<Backend>` singleton with `Arc<Mutex<Vec<ClipboardEntry>>>` history shared with a background monitor thread.

**Swift frontend** (`SwiftApp/`) — a menu-bar-only app (`LSUIElement: true`) using SwiftUI + AppKit:

- [CopyAttachApp.swift](clipboard-manager/SwiftApp/CopyAttachApp.swift) — `@main` entry point with `MenuBarExtra`, `AppDelegate` that starts the Rust backend on launch and manages the settings window and popup toggle.
- [ClipboardBackend.swift](clipboard-manager/SwiftApp/ClipboardBackend.swift) — `ObservableObject` wrapper around the Rust C FFI. Polls `clipboard_get_count()` every 0.5s via Timer, reloads items on change, and periodically calls `clipboard_set_source_app()` to tell Rust which app is frontmost.
- [HistoryPopupView.swift](clipboard-manager/SwiftApp/HistoryPopupView.swift) — `NSPanel` (floating, borderless, non-activating) hosting a SwiftUI `HistoryPopupContent` with keyboard navigation (↑↓ Enter Esc), hover/select highlighting, scroll-to-selected, and per-item app icon + source name display.
- [HotkeyManager.swift](clipboard-manager/SwiftApp/HotkeyManager.swift) — dual-mechanism global hotkey: Carbon `RegisterEventHotKey` (primary) + `NSEvent.addGlobalMonitorForEvents` (fallback). Supports runtime recording of new shortcuts and persists config as JSON in `UserDefaults`. Default is ⌥⌘V.
- [CopyAttach-Bridging-Header.h](clipboard-manager/SwiftApp/CopyAttach-Bridging-Header.h) — C FFI declarations matching the Rust `#[no_mangle] extern "C"` functions, imported by `swiftc` via `-import-objc-header`.

**Data flow**: Rust monitors clipboard in a background thread → Swift polls item count via FFI → on change, Swift reloads labels/thumbnails into `ClipboardItem` enum (`.text` / `.image`) → SwiftUI renders in the popup. On selection, Swift calls `clipboard_select_and_paste()` which writes back to clipboard via `arboard`, sleeps 50ms, then posts Cmd+V via `CGEvent`.

**FFI ownership rules**: Strings returned by Rust (`clipboard_get_item_text`, etc.) must be freed by the caller with `clipboard_free_string`. Byte buffers (`clipboard_get_image_thumb`) must be freed with `clipboard_free_bytes`. The Swift `ClipboardBackend` wrapper handles this.

**Debug logging**: The `debugLog()` function in [HotkeyManager.swift](clipboard-manager/SwiftApp/HotkeyManager.swift) writes to stderr and `/tmp/copyattach_debug.log`. Monitor this file with `tail -f /tmp/copyattach_debug.log` during development.
