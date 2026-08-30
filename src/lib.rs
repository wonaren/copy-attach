//! 🗂️ `CopyAttach` - Rust Backend Library
//!
//! Provides clipboard monitoring, history management, and C FFI for use by a Swift frontend.
//!
//! ## Module layout
//!
//! | Module     | Contents |
//! |------------|----------|
//! | `types`    | `ClipboardEntry` enum, `SourceApp` metadata struct |
//! | `backend`  | `Backend` singleton (`OnceLock`), entry-id generator, constants |
//! | `image`    | PNG encode/decode, thumbnail generation, content hashing |
//! | `history`  | `add_to_history` — dedup, ordering, Vec management |
//! | `db`       | SQLite write-through persistence + legacy JSON migration |
//! | `platform` | OS-specific clipboard/capture/paste backends (macOS/Windows/stub) |
//! | `monitor`  | Background thread polling the system clipboard |
//! | `ffi`      | All `#[no_mangle] extern "C"` functions, `Snapshot` API |
//! | `tests`    | Unit tests (cfg-gated) |

#![allow(dead_code)]

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if crate::backend::debug_log_enabled() {
            crate::backend::debug_log_fmt(format_args!($($arg)*));
        }
    };
}

/// Always-on error/warning logging. Unlike `debug_log!`, this is not gated by
/// the debug-logging preference: real failures should still be observable in
/// release builds (they are rare, but crucial for support). The settings UI
/// only controls verbose/debug logging, not these errors.
macro_rules! error_log {
    ($($arg:tt)*) => {
        crate::backend::error_log_fmt(format_args!($($arg)*))
    };
}

pub(crate) use debug_log;
pub(crate) use error_log;

mod types;
mod backend;
mod image;
mod history;
mod db;
mod ignore;

mod platform;

mod monitor;
mod ffi;

#[cfg(feature = "stress-test")]
pub mod stress;

#[cfg(test)]
mod tests;

#[cfg(all(test, feature = "stress-test"))]
mod bench_tests;
