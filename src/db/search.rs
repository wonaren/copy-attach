use rusqlite::Connection;

use crate::db::FTS_MAX_INDEXED_TEXT_LEN;

pub(crate) fn search_history(conn: &Connection, query: &str) -> Vec<u64> {
    let mut ids = Vec::new();
    let like = format!("%{}%", escape_like(query));

    if query.chars().count() >= 3 {
        let phrase = fts_phrase(query);
        let mut stmt = match conn.prepare(
            "SELECT clipboard_history.entry_id
             FROM clipboard_fts
             JOIN clipboard_history ON clipboard_history.id = clipboard_fts.rowid
             WHERE clipboard_fts MATCH ?1
               AND clipboard_history.id NOT IN (SELECT row_id FROM clipboard_deleted)",
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

        let mut stmt = match conn.prepare(
            "SELECT entry_id FROM clipboard_history
             WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
               AND entry_type = 0 AND length(text) > ?1 AND text LIKE ?2 ESCAPE '\\'",
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to prepare FTS-cap LIKE search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(
            rusqlite::params![FTS_MAX_INDEXED_TEXT_LEN, &like],
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
    } else {
        let mut stmt = match conn.prepare(
            "SELECT entry_id FROM clipboard_history
             WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
               AND entry_type = 0 AND text LIKE ?1 ESCAPE '\\'",
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to prepare LIKE search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![&like], |row| row.get::<_, i64>(0)) {
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

    let mut meta_stmt = match conn.prepare(
        "SELECT entry_id FROM clipboard_history
         WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
           AND (label LIKE ?1 ESCAPE '\\'
                OR custom_label LIKE ?1 ESCAPE '\\'
                OR source_name LIKE ?1 ESCAPE '\\')",
    ) {
        Ok(s) => s,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to prepare metadata LIKE search: {e}");
            return ids;
        }
    };
    let meta_rows = match meta_stmt.query_map(rusqlite::params![&like], |row| row.get::<_, i64>(0)) {
        Ok(r) => r,
        Err(e) => {
            crate::error_log!("CopyAttach: metadata LIKE search failed: {e}");
            return ids;
        }
    };
    for row in meta_rows {
        match row {
            Ok(id) => ids.push(id as u64),
            Err(e) => crate::error_log!("CopyAttach: metadata search row read error: {e}"),
        }
    }

    if ids.len() > 1 {
        let mut seen = std::collections::HashSet::with_capacity(ids.len());
        ids.retain(|id| seen.insert(*id));
    }

    ids
}

fn fts_phrase(query: &str) -> String {
    format!("\"{}\"", query.replace('"', "\"\""))
}

fn escape_like(query: &str) -> String {
    query
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

pub(crate) fn load_text_by_db_id(conn: &Connection, db_id: i64) -> Option<String> {
    let text: String = conn
        .query_row(
            "SELECT text FROM clipboard_history WHERE id = ?1",
            rusqlite::params![db_id],
            |row| row.get(0),
        )
        .map_err(|e| crate::error_log!("CopyAttach: failed to load text for db_id={db_id}: {e}"))
        .ok()?;
    if !crate::backend::claim_pages(text.as_ptr(), text.capacity()) {
        crate::backend::mark_pages_reusable(text.as_ptr(), text.capacity());
        crate::error_log!("CopyAttach: text body for db_id={db_id} could not be claimed — reported as unreadable");
        return None;
    }
    Some(text)
}
