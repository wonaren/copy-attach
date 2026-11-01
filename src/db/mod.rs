mod schema;
mod crud;
mod migration;
mod search;
pub(crate) mod backup;

pub(crate) use schema::{classify_db_error, ensure_history_table, open_db, DbFailure};
#[cfg(any(not(feature = "stress-test"), feature = "demo-data", test))]
pub(crate) use schema::{METADATA_VERSION, migrate_one_image_row, migrate_one_thumbnail_row};
pub(crate) use schema::FTS_MAX_INDEXED_TEXT_LEN;
pub(crate) use schema::{bump_entry_id_watermark, entry_id_watermark, import_favorites, load_favorites, prune_orphan_favorites, set_favorite};
pub(crate) use schema::{load_undo_budget_bytes, store_undo_budget_bytes};
#[cfg(feature = "migration")]
pub(crate) use schema::get_persist_dir;
pub(crate) use crud::{insert_entry_to_db, load_history_from_db, persist_entry_to_db, seed_first_launch_tips, trim_db_history, update_entry_custom_label};
pub(crate) use crud::{
    delete_matching_entry, history_row_payload_bytes, newest_deleted_row, pending_undo_evictions,
    purge_expired_deleted_rows, soft_delete_row, undo_depth,
};
pub(crate) use migration::migrate_from_json_to_db;
#[cfg(all(feature = "migration", test))]
pub(crate) use migration::migrate_from_json_to_db_at;
pub(crate) use search::{load_text_by_db_id, search_history};
