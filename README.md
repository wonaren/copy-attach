# CopyAttach

A full-featured macOS clipboard manager with a **Rust backend** and **native SwiftUI/AppKit frontend**. Monitors clipboard changes, stores text and image history (up to 1000 items), persists to SQLite, and provides a floating overlay UI via a customizable global hotkey.

## Features

- Automatic clipboard monitoring — captures both text and images in real-time
- Text and Image support — stores content with thumbnail previews (up to 1000 items)
- SQLite persistence — history survives app restarts (write-through strategy, mmap-backed)
- Customizable global hotkey — defaults to Option+Cmd+V, changeable via Settings
- One-click select and paste — choose an item to copy it to clipboard and auto-paste via Cmd+V simulation
- Permission request UI — detects missing Accessibility permissions, one-click button to open System Settings
- Native SwiftUI settings window — permissions, hotkey customization, statistics, usage tips
- Menu bar icon — quick access to popup and settings
- Background agent — runs as a menu bar app (no Dock icon)

## Requirements

- macOS 14.0+ (Sonoma or newer)
- Xcode 16+ (for building Swift frontend)
- Rust 1.75+ (for building Rust backend)

## Build & Run

```bash
./build.sh
open "CopyAttach.app"
```

## Usage

- **Option+Cmd+V** (customizable) — show/hide clipboard history overlay
- **Up/Down** — navigate through history
- **Enter** — select and paste
- **Esc** — close overlay
- Click an item or press Enter to copy it back to clipboard and auto-paste

## Debug

```bash
tail -f /tmp/copyattach_debug.log
```

## Architecture

```
┌─────────────────────────────────────────────┐
│           Swift Frontend (macOS)            │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │ Settings  │  │  Popup   │  │ Menu Bar  │ │
│  │  Window   │  │  Overlay │  │   Icon    │ │
│  └─────┬────┘  └────┬─────┘  └─────┬─────┘ │
│        │             │              │       │
│  ┌─────┴─────────────┴──────────────┴─────┐ │
│  │     ClipboardBackend (Swift FFI)       │ │
│  │   (Snapshots via clipboard_snapshot_*) │ │
│  └──────────────────┬──────────────────────┘ │
└─────────────────────┼────────────────────────┘
                      │ C FFI
┌─────────────────────┴────────────────────────┐
│         Rust Backend (cdylib)                │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Clipboard   │  │  History Management  │  │
│  │  Monitor     │  │  (dedup, 1000 limit) │  │
│  │  (300ms poll)│  └──────────────────────┘  │
│  └──────────────┘  ┌──────────────────────┐  │
│  ┌──────────────┐  │  SQLite Persistence  │  │
│  │  Image Proc  │  │  (write-through)     │  │
│  │  (PNG/thumb) │  └──────────────────────┘  │
│  └──────────────┘                             │
└──────────────────────────────────────────────┘
```

**Data flow**: Rust monitors clipboard in a background thread (NSPasteboard changeCount lightweight check, then arboard read). New entries are written through to SQLite immediately. Swift polls `clipboard_get_count()` every 500ms; on change, it acquires a lock-free snapshot via `clipboard_snapshot_acquire()`, reads all items, then releases. On user selection, `clipboard_select_and_paste_by_id()` writes the entry back to the system clipboard and simulates Cmd+V via CGEventPost.

**FFI ownership**: Rust strings must be freed with `clipboard_free_string`, byte buffers with `clipboard_free_bytes`. The Swift `ClipboardBackend` wrapper handles all deallocation.

## Project Structure

```
├── src/
│   └── lib.rs              # Rust backend (C FFI, clipboard monitor, SQLite, image processing)
├── SwiftApp/
│   ├── CopyAttachApp.swift  # App entry point (MenuBarExtra, AppDelegate, Settings UI)
│   ├── ClipboardBackend.swift  # Rust FFI wrapper, polling, item types
│   ├── HistoryPopupView.swift  # Floating NSPanel overlay with keyboard navigation
│   ├── HotkeyManager.swift  # Global hotkey (Carbon + NSEvent monitor), debug logging
│   ├── Info.plist
│   └── CopyAttach-Bridging-Header.h  # C FFI declarations
├── assets/
│   ├── icon.svg             # App icon source
│   └── AppIcon.icns         # Generated icon (by build.sh via sips + iconutil)
├── build.sh                 # Build script (cargo + swiftc + codesign)
├── Cargo.toml               # Rust crate config (cdylib + rlib, rusqlite bundled)
├── CLAUDE.md                # Developer guide (Claude Code instructions)
└── README.md
```

## License

MIT
