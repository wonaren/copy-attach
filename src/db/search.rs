use rusqlite::Connection;

use crate::db::FTS_MAX_INDEXED_TEXT_LEN;

/// Case-insensitive substring search over the stored full text.
///
/// Queries of ≥3 Unicode scalars go through the FTS5 trigram index (substring
/// semantics, full-Unicode case folding) PLUS a LIKE fallback over rows the
/// index excludes (texts longer than [`FTS_MAX_INDEXED_TEXT_LEN`] characters —
/// see schema.rs; the cap keeps the index and the capture-path insert cost
/// bounded for huge pastes). The fallback preserves the ≥3-char substring
/// promise for those rows: they are rare, so the scan is bounded to them.
/// Shorter queries cannot form a trigram at all, so they fall back to a LIKE
/// scan over the full text column.
///
/// The LIKE fallback is DELIBERATE, not a leftover: matching only the bounded
/// previews for 1-2 char queries would silently drop matches in the middle of
/// long documents — a semantic regression for a latency gain. Known
/// limitation, unchanged from before: SQLite's LIKE folds ASCII case only, so
/// a query relying on non-ASCII case folding (e.g. `é` matching `É`) misses
/// those variants in the LIKE paths; the trigram path (≥3 chars, indexed rows)
/// folds Unicode. Returns matching entry_ids (the stable Rust IDs, not SQLite
/// rowids).
pub(crate) fn search_history(conn: &Connection, query: &str) -> Vec<u64> {
    let mut ids = Vec::new();
    if query.chars().count() >= 3 {
        let phrase = fts_phrase(query);
        let mut stmt = match conn.prepare(
            "SELECT clipboard_history.entry_id
             FROM clipboard_fts
             JOIN clipboard_history ON clipboard_history.id = clipboard_fts.rowid
             WHERE clipboard_fts MATCH ?1",
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to prepare FTS search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![phrase], |row| row.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                crate::error_log!("CopyAttach: FTS search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => crate::error_log!("CopyAttach: FTS search row read error: {e}"),
            }
        }

        // LIKE fallback over rows the trigram index excludes (huge texts above
        // the cap): the index is the fast path, the LIKE scan is bounded to
        // the rare oversized rows, and the substring semantics never silently
        // drop a huge document from search results.
        let like = format!("%{}%", escape_like(query));
        let mut stmt = match conn.prepare(
            "SELECT entry_id FROM clipboard_history
             WHERE entry_type = 0 AND length(text) > ?1 AND text LIKE ?2 ESCAPE '\\'",
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to prepare FTS-cap LIKE search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(
            rusqlite::params![FTS_MAX_INDEXED_TEXT_LEN, like],
            |row| row.get::<_, i64>(0),
        ) {
            Ok(r) => r,
            Err(e) => {
                crate::error_log!("CopyAttach: FTS-cap LIKE search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => crate::error_log!("CopyAttach: FTS-cap LIKE search row read error: {e}"),
            }
        }
        // An oversized row can be double-reported while a legacy index still
        // holds it (the startup cleanup removes those); dedup defensively.
        if ids.len() > 1 {
            let mut seen = std::collections::HashSet::with_capacity(ids.len());
            ids.retain(|id| seen.insert(*id));
        }
    } else {
        let like = format!("%{}%", escape_like(query));
        let mut stmt = match conn.prepare(
            "SELECT entry_id FROM clipboard_history
             WHERE entry_type = 0 AND text LIKE ?1 ESCAPE '\\'",
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to prepare LIKE search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![like], |row| row.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                crate::error_log!("CopyAttach: LIKE search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => crate::error_log!("CopyAttach: LIKE search row read error: {e}"),
            }
        }
    }
    ids
}

/// Wrap a user query as an FTS5 phrase, doubling embedded quotes so arbitrary
/// input (including `*`, `-`, parens, quotes) is matched literally.
fn fts_phrase(query: &str) -> String {
    format!("\"{}\"", query.replace('"', "\"\""))
}

/// Escape `%`/`_`/`\` so a LIKE pattern matches the query literally, mirroring
/// the substring semantics of the FTS path (and the pre-index `contains`).
fn escape_like(query: &str) -> String {
    query
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// Load the full text body for a row by its SQLite rowid (== `db_id`).
pub(crate) fn load_text_by_db_id(conn: &Connection, db_id: i64) -> Option<String> {
    let text: String = conn
        .query_row(
            "SELECT text FROM clipboard_history WHERE id = ?1",
            rusqlite::params![db_id],
            |row| row.get(0),
        )
        .map_err(|e| crate::error_log!("CopyAttach: failed to load text for db_id={db_id}: {e}"))
        .ok()?;
    // rusqlite may have grown this buffer over reusable-marked pages; claim
    // them before the caller reads the body (same contract as blob reads).
    crate::backend::claim_pages(text.as_ptr(), text.capacity());
    Some(text)
}
