//! Platform abstraction layer.
//!
//! Unifies the OS-specific clipboard, capture, and paste-simulation surface
//! behind one set of `pub(crate)` functions. Callers (`monitor`, `ffi::*`)
//! never touch OS APIs directly. Implementations are selected at compile time:
//!
//! | Module    | Target |
//! |-----------|--------|
//! | `macos`   | `target_os = "macos"` |
//! | `windows` | `cfg(windows)` |
//! | `stub`    | everything else (explicit failure, never silent fallback behavior in the hot path) |
//!
//! Windows note: `arboard::Clipboard::new()` opens the system clipboard and
//! holds it open until the handle is dropped. A long-lived handle would block
//! every other application from writing to the clipboard, so all clipboard
//! access on Windows opens a fresh handle per operation. The monitor only
//! touches the clipboard after a sequence-number change, so the per-event
//! open/close cost is negligible.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod windows;
#[cfg(not(any(target_os = "macos", windows)))]
mod stub;

#[cfg(target_os = "macos")]
pub(crate) use macos::*;
#[cfg(windows)]
pub(crate) use windows::*;
#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) use stub::*;
