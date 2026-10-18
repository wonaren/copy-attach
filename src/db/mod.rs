//! `SQLite` persistence layer — write-through DB for clipboard history.
//!
//! Schema: `clipboard_history` with columns for both text and image entries.
//! All mutations go through write-through: the monitor thread and the
//! select-and-paste path each insert, deduplicate, and trim on every capture.
//!
//! Submodules: `schema` (connection + table/FTS index), `crud` (load/insert/
//! dedup/trim), `migration` (legacy JSON), `search` (FTS/LIKE + text loading).
//! The `pub(crate) use` re-exports keep the historical `crate::db::*` paths
//! stable for the FFI layer, the monitor, and the test suite.

mod schema;
mod crud;
mod migration;
mod search;
pub(crate) mod backup;

pub(crate) use schema::{classify_db_error, ensure_history_table, open_db, DbFailure};
// The image-hash migration driver lives in ffi/init.rs and is compiled out of
// stress-test builds (their DBs are freshly generated with the stable
// algorithm), so these re-exports follow the same gate; tests keep access.
#[cfg(any(not(feature = "stress-test"), test))]
pub(crate) use schema::{METADATA_VERSION, migrate_one_image_row, migrate_one_thumbnail_row};
pub(crate) use schema::FTS_MAX_INDEXED_TEXT_LEN;
pub(crate) use schema::{bump_entry_id_watermark, entry_id_watermark, import_favorites, load_favorites, prune_orphan_favorites, set_favorite};
#[cfg(feature = "migration")]
pub(crate) use schema::get_persist_dir;
pub(crate) use crud::{insert_entry_to_db, load_history_from_db, persist_entry_to_db, seed_first_launch_tips, trim_db_history, update_entry_custom_label};
pub(crate) use migration::migrate_from_json_to_db;
/// Test-only entry point (temp-dir parameterized); the production lib resolves
/// the real persist dir inside `migrate_from_json_to_db`.
#[cfg(all(feature = "migration", test))]
pub(crate) use migration::migrate_from_json_to_db_at;
pub(crate) use search::{load_text_by_db_id, search_history};
