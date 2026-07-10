# 🗂️ CopyAttach

A full-featured macOS clipboard manager with a **Rust backend** and **native SwiftUI/AppKit frontend**. Monitors clipboard changes, stores text & image history (up to 1000 items), and provides a floating overlay UI via a customizable global hotkey.

## Features

- 📋 **Automatic clipboard monitoring** — captures both text and images in real-time
- 🖼️ **Text & Image support** — stores content and image snapshots (up to 1000 items)
- ⚡ **Customizable global hotkey** — defaults to ⌥⌘V, changeable via Settings
- 🎯 **One-click select & paste** — choose an item to copy it to clipboard and auto-paste
- 🔐 **Permission request UI** — detects missing Accessibility permissions, one-click button to open System Settings
- 🖥️ **Native SwiftUI settings window** — permissions, hotkey customization, statistics, usage tips
- 📎 **Menu bar icon** — quick access to popup and settings
- 🔄 **Background agent** — runs in background (no Dock icon)

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

- **⌥⌘V** (customizable) — show/hide clipboard history overlay
- **↑↓** — navigate through history
- **Enter** — select & paste
- **Esc** — close overlay
- **Click** an item or press Enter to copy it back to clipboard and auto-paste

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
│  └──────────────────┬──────────────────────┘ │
└─────────────────────┼────────────────────────┘
                      │
┌─────────────────────┴────────────────────────┐
│         Rust Backend (cdylib)                │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Clipboard   │  │  History Management  │  │
│  │  Monitor     │  │  (dedup, 1000 limit) │  │
│  └──────────────┘  └──────────────────────┘  │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Image Proc  │  │  Paste Simulation   │  │
│  │  (PNG encode)│  │  (CGEventPost)      │  │
│  └──────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────┘
```

## Project Structure

```
copy-attach/
├── src/
│   └── lib.rs              # Rust backend (C FFI)
├── SwiftApp/
│   ├── CopyAttachApp.swift  # App entry point
│   ├── ClipboardBackend.swift
│   ├── HistoryPopupView.swift
│   ├── HotkeyManager.swift
│   ├── Info.plist
│   └── CopyAttach-Bridging-Header.h
├── Cargo.toml
├── build.sh
└── README.md
```

## Version

0.1-beta

## License

MIT
