# CopyAttach

A full-featured macOS clipboard manager with a **Rust backend** and **native SwiftUI/AppKit frontend**. Monitors clipboard changes, stores text and image history (up to 1000 items), persists to SQLite, and provides a floating overlay UI via a customizable global hotkey.

## Features

- Automatic clipboard monitoring — captures both text and images in real-time
- Text and Image support — stores content with thumbnail previews (up to 1000 items)
- SQLite persistence — history survives app restarts (write-through strategy, mmap-backed)
- Customizable global hotkey — defaults to ⌥⌘V, changeable via Settings
- One-click select and paste — choose an item to copy it to clipboard and auto-paste via Cmd+V simulation
- Permission request UI — detects missing Accessibility permissions, one-click button to open System Settings
- Native SwiftUI settings window — permissions, hotkey customization, statistics, usage tips
- Spacebar preview — press Space to preview full text or image before pasting
- App source tracking — shows which app each clipboard entry came from
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

Debug logging showing Rust + Swift output:
```bash
tail -f /tmp/copyattach_debug.log
```

## Usage

- **⌥⌘V** (customizable) — show/hide clipboard history overlay
- **↑/↓** — navigate through history items
- **␣** — open preview of the selected item
- **⏎** — select and paste (copies back to clipboard + Cmd+V)
- **⎋** — close overlay or preview
- Click an item to select and paste

## Architecture

```
┌─────────────────────────────────────────────┐
│           Swift Frontend (macOS)            │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │ Settings  │  │  Popup   │  │  Preview  │ │
│  │  Window   │  │ NSPanel  │  │ NSPanel   │ │
│  └─────┬────┘  └────┬─────┘  └─────┬─────┘ │
│        │             │              │       │
│  ┌─────┴─────────────┴──────────────┴─────┐ │
│  │     ClipboardBackend (Swift FFI)       │ │
│  │   (0.5s poll, Snapshot API reads,      │ │
│  │    thumbnail NSCache, source app        │ │
│  │    tracker via NSWorkspace)             │ │
│  └──────────────────┬──────────────────────┘ │
└─────────────────────┼────────────────────────┘
                      │ C FFI (objc-free, ~40 exported functions)
┌─────────────────────┴────────────────────────┐
│         Rust Backend (cdylib)                │
│                                             │
│  ┌──────────────┐  ┌──────────────────────┐ │
│  │  Clipboard   │  │  History Management  │ │
│  │  Monitor     │  │  (Arc<Mutex<Vec>>,   │ │
│  │  (300ms poll,│  │   dedup by text/hash, │ │
│  │   changeCount│  │   3000 cap, monotonic │ │
│  │   check)     │  │   entry_id)           │ │
│  └──────────────┘  └──────────────────────┘ │
│  ┌──────────────┐  ┌──────────────────────┐ │
│  │  Image Proc  │  │  SQLite Persistence  │ │
│  │  (PNG encode,│  │  (write-through,     │ │
│  │   Lanczos3   │  │   mmap BLOB reads,   │ │
│  │   thumbnail, │  │   512KB page cache)  │ │
│  │   hash dedup)│  │                      │ │
│  └──────────────┘  └──────────────────────┘ │
│                                             │
│  ┌──────────────────────────────────────┐   │
│  │  Cmd+V Simulation (CGEventPost)      │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

**Data flow**: Rust monitors clipboard in a background thread (NSPasteboard `changeCount` lightweight check, then `arboard` read). New entries are written through to SQLite immediately. Swift polls `clipboard_get_count()` every 500ms; on change, it acquires a lock-free snapshot via `clipboard_snapshot_acquire()`, reads all items, then releases. On user selection, `clipboard_select_and_paste_by_id()` writes the entry back to the system clipboard and simulates Cmd+V via CGEventPost. The Rust side sets `last_seen_text` / `last_seen_image_hash` before writing to suppress re-capture.

**FFI ownership**: Rust-allocated strings must be freed with `clipboard_free_string`, byte buffers with `clipboard_free_bytes`. The Swift `ClipboardBackend` wrapper handles all deallocation.

## Hotkey System

Two redundant mechanisms for global hotkey detection:
1. **Carbon RegisterEventHotKey** — system-level, works when app is backgrounded
2. **NSEvent global monitor** — fallback for Carbon edge cases

Both require Accessibility permissions (`AXIsProcessTrusted`). Hotkey configuration is persisted to `UserDefaults` as JSON via `Codable`.

## Project Structure

```
├── src/
│   └── lib.rs              # Rust backend (~1786 lines): C FFI, clipboard monitor,
│                               SQLite, image processing (PNG / thumbnail / hash),
│                               paste simulation
├── SwiftApp/
│   ├── CopyAttachApp.swift      # App entry (MenuBarExtra), AppDelegate,
│                                   settings window (InlineSettingsView)
│   ├── ClipboardBackend.swift   # Rust FFI wrapper, 0.5s polling timer,
│                                   Snapshot API reads, item types enum,
│                                   thumbnail NSCache, app icon lookup
│   ├── HistoryPopupView.swift   # Floating NSPanel overlay, SwiftUI list,
│                                   keyboard nav (↑↓⏎⎋␣), item rows with
│                                   visual-width CJK truncation
│   ├── PreviewWindow.swift      # Non-key NSPanel, full-size text/image
│                                   preview, auto-resizing, content height cache
│   ├── HotkeyManager.swift      # Carbon + NSEvent dual hotkey registration,
│                                   interactive recording, debugLog()
│   ├── CopyAttach-Bridging-Header.h  # C FFI declarations (~60 functions)
│   └── Info.plist
├── assets/
│   ├── icon.svg             # App icon source
│   └── AppIcon.icns         # Generated icon (by build.sh via sips + iconutil)
├── build.sh                 # Build script (cargo release + swiftc + codesign)
├── Cargo.toml               # Rust crate (cdylib + rlib, rusqlite bundled, image/png)
├── CLAUDE.md                # Developer guide (Claude Code instructions)
└── README.md
```

## License

MIT
