// Memory probes — isolate the FTS index's resident-memory cost.
//
// The trigram FTS index lives in the same DB file as the base table. With the
// app's real connection settings (mmap disabled + 4MB LRU page cache) index
// pages become resident as they are read
// (searches, and the triggers' insert/delete on every capture), so a large
// index can inflate process RSS. These probes insert an identical corpus into
// a DB WITH the FTS index and one WITHOUT, and print the RSS at each stage.
// Run them separately (each must be a fresh process):
//   cargo test --features stress-test memory_probe_fts_index -- --nocapture
//   cargo test --features stress-test memory_probe_no_fts_index -- --nocapture

use crate::backend::new_entry_id;
use crate::types::ClipboardEntry;
use rusqlite::Connection;

/// Current process RSS in KB (macOS `ps -o rss=`; KB on darwin).
fn probe_rss_kb() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p"])
        .arg(std::process::id().to_string())
        .output()
        .expect("memory probe: ps failed");
    String::from_utf8_lossy(&out.stdout).trim().parse().expect("memory probe: parse rss")
}

/// Deterministic mixed-size corpus (3000 texts, ~1.3KB avg → ~4MB total):
/// mimics a real history small enough that the trigram index (~3.5× text) still
/// leaves the whole DB file under the 32MB mmap cap — the regime where index
/// pages are mmap'd into the process and become resident memory.
fn probe_corpus() -> Vec<String> {
    (0..3000)
        .map(|i| {
            let size = match i % 4 {
                0 => 150,
                1 => 600,
                2 => 1_500,
                _ => 3_000,
            };
            let head = format!("clipboard item number {i}: ");
            let filler = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor ".repeat(size / 66);
            format!("{head}{filler}")
        })
        .collect()
}

/// Open the real app connection settings (no mmap + 4MB LRU page cache).
fn probe_open_db(path: &std::path::Path) -> Connection {
    let conn = Connection::open(path).expect("memory probe: open db");
    conn.execute_batch(
        "PRAGMA mmap_size = 0;
         PRAGMA cache_size = -4096;",
    )
    .expect("memory probe: pragma");
    conn
}

#[test]
fn memory_probe_fts_index() {
    let dir = std::env::temp_dir().join(format!("copyattach_memprobe_fts_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let db_path = dir.join("history.db");
    let _ = std::fs::remove_file(&db_path);

    let rss0 = probe_rss_kb();
    let conn = probe_open_db(&db_path);
    crate::db::ensure_history_table(&conn).expect("memory probe: schema");
    let rss1 = probe_rss_kb();

    for (i, text) in probe_corpus().iter().enumerate() {
        let entry = ClipboardEntry::text_entry(new_entry_id(), text, i as u64, String::new(), String::new(), 0);
        crate::db::insert_entry_to_db(&conn, &entry, Some(text), None, None).ok();
    }
    let rss2 = probe_rss_kb();

    let loaded = crate::db::load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 3000);
    let rss3 = probe_rss_kb();

    for q in ["lorem", "ipsum", "clipboard", "adipiscing", "consectetur", "amet", "dolor", "elit", "tempor", "1234"] {
        let _ = crate::db::search_history(&conn, q);
    }
    let rss4 = probe_rss_kb();

    let db_size = std::fs::metadata(&db_path).map(|m| m.len()).unwrap_or(0);
    println!(
        "[FTS]   file={}B  rss(KB): start={} schema={} insert={} load={} search={}",
        db_size, rss0, rss1, rss2, rss3, rss4
    );
    drop(conn);
    let _ = std::fs::remove_file(&db_path);
    let _ = std::fs::remove_dir(&dir);
}

#[test]
fn memory_probe_no_fts_index() {
    let dir = std::env::temp_dir().join(format!("copyattach_memprobe_nofts_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let db_path = dir.join("history.db");
    let _ = std::fs::remove_file(&db_path);

    let rss0 = probe_rss_kb();
    let conn = probe_open_db(&db_path);
    // Base table only — no FTS index. Same schema as the app minus the FTS.
    conn.execute_batch(
        "CREATE TABLE clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_id        INTEGER NOT NULL DEFAULT 0,
            entry_type      INTEGER NOT NULL,
            text            TEXT,
            png_data        BLOB,
            width           INTEGER,
            height          INTEGER,
            thumb_data      BLOB,
            thumb_width     INTEGER,
            thumb_height    INTEGER,
            hash            INTEGER,
            timestamp       INTEGER NOT NULL DEFAULT 0,
            source_name     TEXT NOT NULL DEFAULT '',
            source_bundle_id TEXT NOT NULL DEFAULT '',
            preview         TEXT NOT NULL DEFAULT '',
            label           TEXT NOT NULL DEFAULT ''
        );",
    )
    .expect("memory probe: schema");
    let rss1 = probe_rss_kb();

    for (i, text) in probe_corpus().iter().enumerate() {
        let entry = ClipboardEntry::text_entry(new_entry_id(), text, i as u64, String::new(), String::new(), 0);
        crate::db::insert_entry_to_db(&conn, &entry, Some(text), None, None).ok();
    }
    let rss2 = probe_rss_kb();

    let loaded = crate::db::load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 3000);
    let rss3 = probe_rss_kb();

    for q in ["lorem", "ipsum", "clipboard", "adipiscing", "consectetur", "amet", "dolor", "elit", "tempor", "1234"] {
        let _ = crate::db::search_history(&conn, q);
    }
    let rss4 = probe_rss_kb();

    let db_size = std::fs::metadata(&db_path).map(|m| m.len()).unwrap_or(0);
    println!(
        "[NOFTS] file={}B  rss(KB): start={} schema={} insert={} load={} search={}",
        db_size, rss0, rss1, rss2, rss3, rss4
    );
    drop(conn);
    let _ = std::fs::remove_file(&db_path);
    let _ = std::fs::remove_dir(&dir);
}
