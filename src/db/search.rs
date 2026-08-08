use rusqlite::Connection;

/// Case-insensitive substring search over the stored full text.
///
/// Queries of ≥3 Unicode scalars go through the FTS5 trigram index (substring
/// semantics, full-Unicode case folding). Shorter queries cannot form a
/// trigram, so they fall back to a LIKE scan — trigram's matching floor, not a
/// failure path. Known limitation of that fallback: SQLite's LIKE folds ASCII
/// case only, so a <3-char query that relies on non-ASCII case folding (e.g.
/// `é` matching `É`, Greek case) misses those variants; ≥3-char queries are
/// unaffected (trigram folds Unicode). Returns matching entry_ids (the stable
/// Rust IDs, not SQLite rowids).
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
                eprintln!("CopyAttach: failed to prepare FTS search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![phrase], |row| row.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: FTS search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => eprintln!("CopyAttach: FTS search row read error: {e}"),
            }
        }
    } else {
        let like = format!("%{}%", escape_like(query));
        let mut stmt = match conn.prepare(
            "SELECT entry_id FROM clipboard_history
             WHERE entry_type = 0 AND text LIKE ?1 ESCAPE '\\'",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("CopyAttach: failed to prepare LIKE search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![like], |row| row.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: LIKE search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => eprintln!("CopyAttach: LIKE search row read error: {e}"),
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
    conn.query_row(
        "SELECT text FROM clipboard_history WHERE id = ?1",
        rusqlite::params![db_id],
        |row| row.get(0),
    )
    .map_err(|e| eprintln!("CopyAttach: failed to load text for db_id={db_id}: {e}"))
    .ok()
}
