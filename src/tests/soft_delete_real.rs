use std::sync::Once;

static INIT: Once = Once::new();

fn ensure_real_backend() {
    INIT.call_once(|| {
        assert!(
            std::env::var_os("COPYATTACH_DATA_DIR").is_some(),
            "test_soft_delete_real_path mutates the live history; set COPYATTACH_DATA_DIR to a scratch directory"
        );
        let rc = crate::ffi::clipboard_init_with_threshold_and_favorites(10_000, std::ptr::null());
        assert_eq!(rc, 1, "clipboard_init must succeed against COPYATTACH_DATA_DIR");
    });
}

fn sql(conn: &rusqlite::Connection, q: &str) -> i64 {
    conn.query_row(q, [], |r| r.get::<_, i64>(0)).unwrap_or(-1)
}

fn footprint_kb() -> (u64, u64, u64) {
    let out = std::process::Command::new("vmmap")
        .args(["-summary", &std::process::id().to_string()])
        .output();
    let text = match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(_) => return (0, 0, 0),
    };
    for line in text.lines() {
        if !line.starts_with("Writable regions:") {
            continue;
        }
        let field = |name: &str| -> u64 {
            let Some(idx) = line.find(&format!("{name}=")) else { return 0 };
            let rest = &line[idx + name.len() + 1..];
            let num: String = rest
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect();
            let value: f64 = num.parse().unwrap_or(0.0);
            match rest.chars().nth(num.len()) {
                Some('G') => (value * 1024.0 * 1024.0) as u64,
                Some('M') => (value * 1024.0) as u64,
                _ => value as u64,
            }
        };
        return (field("written"), field("resident"), field("swapped_out"));
    }
    (0, 0, 0)
}

fn rss_kb() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    out.trim().parse().unwrap_or(0)
}

#[test]
#[ignore = "spawns the monitor thread; run explicitly with COPYATTACH_DATA_DIR set"]
fn test_soft_delete_real_path() {
    ensure_real_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let (live_before, has_col, version, total_before) = {
        let conn = b.db.lock().unwrap();
        (
            sql(&conn, "SELECT COUNT(*) FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)"),
            sql(&conn,
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clipboard_deleted'"),
            sql(&conn, "PRAGMA user_version"),
            sql(&conn, "SELECT COUNT(*) FROM clipboard_history"),
        )
    };
    println!("\n[init] live rows={live_before} side table={has_col} user_version={version}");
    assert_eq!(has_col, 1, "schema migration must create the soft-delete side table");

    let ids: Vec<u64> = {
        let snap = crate::ffi::clipboard_snapshot_acquire();
        assert!(!snap.is_null(), "snapshot acquire");
        let n = crate::ffi::clipboard_snapshot_count(snap);
        let ids = (0..n)
            .map(|i| crate::ffi::clipboard_snapshot_item_id(snap, i) as u64)
            .collect();
        crate::ffi::clipboard_snapshot_release(snap);
        ids
    };
    println!("[snapshot] {} entries", ids.len());
    assert!(!ids.is_empty(), "fixture database must contain entries");

    let (written0, resident0, swapped0) = footprint_kb();
    assert!(
        resident0 > 0 && written0 > 0,
        "vmmap must report a real footprint (written={written0} resident={resident0}); instrument unusable"
    );
    println!(
        "[instrument] writable written={written0}K resident={resident0}K swapped={swapped0}K \
         (ps rss={}K)",
        rss_kb()
    );

    let rss_before_delete = rss_kb();
    let baseline_depth = crate::ffi::clipboard_undo_depth() as usize;
    let mut deleted = 0usize;
    for id in &ids {
        if crate::ffi::clipboard_delete_by_id(*id) != 0 {
            deleted += 1;
        }
    }
    let rss_after_delete = rss_kb();
    let (written_del, resident_del, swapped_del) = footprint_kb();
    crate::ffi::clipboard_shrink_db_memory();
    let (written_del2, resident_del2, _) = footprint_kb();
    println!(
        "[delete] writable written={written0}->{written_del} (after shrink {written_del2}) \
         resident={resident0}->{resident_del} (after shrink {resident_del2}) swapped={swapped_del} \
         | ps rss {rss_before_delete}->{rss_after_delete} KB"
    );
    let depth = crate::ffi::clipboard_undo_depth() as usize;
    let (live_after_delete, deleted_rows, retained_bytes) = {
        let conn = b.db.lock().unwrap();
        (
            sql(&conn, "SELECT COUNT(*) FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)"),
            sql(&conn, "SELECT COUNT(*) FROM clipboard_deleted"),
            sql(&conn,
                "SELECT COALESCE(SUM(COALESCE(LENGTH(h.text),0) + COALESCE(LENGTH(h.png_data),0)
                 + COALESCE(LENGTH(h.thumb_data),0)), 0)
                 FROM clipboard_deleted d JOIN clipboard_history h ON h.id = d.row_id"),
        )
    };
    println!(
        "[delete] deleted={deleted}/{} undo_depth={depth} live={live_after_delete} \
         deleted_rows={deleted_rows} retained_bytes={retained_bytes} rss {}->{} KB (delta {} KB)",
        ids.len(),
        rss_before_delete,
        rss_after_delete,
        rss_after_delete as i64 - rss_before_delete as i64
    );
    assert_eq!(deleted, ids.len(), "every delete must succeed");
    assert_eq!(depth, baseline_depth + ids.len(), "undo depth must equal pre-existing depth plus the number of deletions (no step cap)");
    assert_eq!(live_after_delete, 0, "no live rows may remain");
    assert_eq!(deleted_rows, (baseline_depth + ids.len()) as i64, "deleted rows must stay in the table");
    let undo_budget = crate::backend::undo_limit();
    if undo_budget > 0 {
        assert!(
            retained_bytes <= undo_budget,
            "retained deleted payload must fit the byte budget ({retained_bytes} bytes)"
        );
    }

    let rss_before_undo = rss_kb();
    let mut undone = 0usize;
    for _ in 0..deleted {
        if crate::ffi::clipboard_undo_delete() != 0 {
            undone += 1;
        }
    }
    let rss_after_undo = rss_kb();
    crate::ffi::clipboard_shrink_db_memory();
    let rss_after_undo_shrink = rss_kb();
    let (written_undo, resident_undo, swapped_undo) = footprint_kb();
    crate::ffi::clipboard_shrink_db_memory();
    let (written_undo2, resident_undo2, _) = footprint_kb();
    println!(
        "[undo] writable written={written_del}->{written_undo} (after shrink {written_undo2}) \
         resident={resident_del}->{resident_undo} (after shrink {resident_undo2}) swapped={swapped_undo} \
         | ps rss {rss_before_undo}->{rss_after_undo} KB (after shrink {rss_after_undo_shrink})"
    );
    let (live_after_undo, total_after_undo, dup_groups) = {
        let conn = b.db.lock().unwrap();
        (
            sql(&conn, "SELECT COUNT(*) FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)"),
            sql(&conn, "SELECT COUNT(*) FROM clipboard_history"),
            sql(&conn,
                "SELECT COUNT(*) FROM (SELECT entry_type, hash, COUNT(*) c
                 FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                 GROUP BY entry_type, hash HAVING c > 1)"),
        )
    };
    println!(
        "[undo] undone={undone} live={live_after_undo} total_rows={total_after_undo} \
         duplicate_groups={dup_groups} rss {}->{} KB (delta {} KB)",
        rss_before_undo,
        rss_after_undo,
        rss_after_undo as i64 - rss_before_undo as i64
    );
    assert_eq!(undone, deleted, "every undo must succeed");
    assert_eq!(live_after_undo, ids.len() as i64, "every entry must come back");
    assert_eq!(total_after_undo, total_before, "undo must replace each soft-deleted payload row without touching unrelated rows");
    assert_eq!(dup_groups, 0, "undo must not leave duplicate content rows");
    assert_eq!(crate::ffi::clipboard_undo_depth() as usize, baseline_depth, "undo stack must return to its pre-test depth");

    let delete_written_delta = written_del as i64 - written0 as i64;
    let undo_written_delta = written_undo2 as i64 - written_del as i64;
    println!(
        "[memory] written delta: delete={delete_written_delta} KB undo={undo_written_delta} KB \
         | resident delta: delete={} KB undo={} KB",
        resident_del as i64 - resident0 as i64,
        resident_undo2 as i64 - resident_del as i64
    );
    assert!(
        delete_written_delta < 8_000,
        "deleting {} entries must not dirty a per-entry amount of memory \
         (writable written grew {delete_written_delta} KB)",
        ids.len()
    );
    assert!(
        undo_written_delta < 16_000,
        "undoing {} entries must not dirty a per-entry amount of memory \
         (writable written grew {undo_written_delta} KB)",
        ids.len()
    );

    for round in 1..=3 {
        let ids_now: Vec<u64> = {
            let snap = crate::ffi::clipboard_snapshot_acquire();
            assert!(!snap.is_null(), "snapshot acquire");
            let n = crate::ffi::clipboard_snapshot_count(snap);
            let v = (0..n)
                .map(|i| crate::ffi::clipboard_snapshot_item_id(snap, i) as u64)
                .collect();
            crate::ffi::clipboard_snapshot_release(snap);
            v
        };
        for id in &ids_now {
            assert_eq!(crate::ffi::clipboard_delete_by_id(*id), 1, "round {round}: delete");
        }
        for _ in 0..ids_now.len() {
            assert_eq!(crate::ffi::clipboard_undo_delete(), 1, "round {round}: undo");
        }
        let (written, resident, swapped) = footprint_kb();
        println!(
            "[cycle {round}] writable written={written}K resident={resident}K swapped={swapped}K \
             | ps rss={}K",
            rss_kb()
        );
    }
    let (written_cycles, resident_cycles, _) = footprint_kb();
    println!(
        "[cycles] after 3 more delete/undo cycles: written={written_cycles}K resident={resident_cycles}K \
         (delta from first cycle: written={} KB resident={} KB)",
        written_cycles as i64 - written_undo2 as i64,
        resident_cycles as i64 - resident_undo2 as i64
    );
    assert!(
        (written_cycles as i64 - written_undo2 as i64) < 4_000,
        "repeated delete/undo cycles must not ratchet the dirty footprint \
         (written grew {} KB over 3 cycles)",
        written_cycles as i64 - written_undo2 as i64
    );

    crate::ffi::clipboard_cleanup();
}
