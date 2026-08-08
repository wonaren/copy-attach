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

pub(crate) use schema::{ensure_history_table, get_persist_dir, open_db};
pub(crate) use crud::{delete_matching_entry, insert_entry_to_db, load_history_from_db, trim_db_history};
pub(crate) use migration::migrate_from_json_to_db;
pub(crate) use search::{load_text_by_db_id, search_history};
