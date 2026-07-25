//! 🗂️ CopyAttach - Rust Backend Library
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
//! | `macos`    | macOS paste simulation, accessibility permissions (cfg-gated) |
//! | `monitor`  | Background thread polling the system clipboard |
//! | `ffi`      | All `#[no_mangle] extern "C"` functions, `Snapshot` API |
//! | `tests`    | Unit tests (cfg-gated) |

#![allow(dead_code)]

mod types;
mod backend;
mod image;
mod history;
mod db;
mod ignore;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(not(target_os = "macos"))]
mod macos {
    pub(crate) fn check_permission() -> bool { true }
    pub(crate) fn open_preferences() {}
    pub(crate) fn simulate_cmd_v() -> bool {
        eprintln!("Warning: paste simulation only supported on macOS");
        false
    }
    pub(crate) fn pasteboard_change_count() -> Option<i64> { None }
    pub(crate) fn pasteboard_has_files() -> bool { false }
    pub(crate) fn pasteboard_file_paths() -> Vec<String> { vec![] }
}

mod monitor;
mod ffi;

#[cfg(feature = "stress-test")]
pub mod stress;

#[cfg(test)]
mod tests;
