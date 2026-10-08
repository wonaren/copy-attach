// Auto-cleanup threshold, trim-oldest-percent, and dynamic threshold tests.

use crate::history::add_to_history;
use super::{assign_row_ids, fill_and_trim_to, make_text, simulate_trim_oldest_percent, simulate_trim_oldest_percent_with_favorites};

/// Build `n` distinct text entries carrying real row ids, newest first — the
/// shape the production list has (head = newest = largest db_id).
fn with_rows(n: usize) -> Vec<crate::types::ClipboardEntry> {
    let mut hist: Vec<_> = (0..n).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    assign_row_ids(&mut hist);
    hist
}

/// Guards the temp-file TTL sweep used by both `Paste/` and `Drag/`.
///
/// The behaviour this pins down is the drag directory's old rule: it deleted
/// every file at the START of the next image drag, so the last drag's PNG was
/// retained forever for anyone who dragged an image only once (measured: a
/// 207 KB PNG from the previous day still on disk across several restarts).
/// The sweep must be age-based, and must leave fresh files alone — a drop
/// destination can still be reading the file the current drag produced.
#[test]
fn test_temp_purge_removes_only_aged_out_files() {
    use std::time::{Duration, SystemTime};

    let dir = std::env::temp_dir().join(format!("CopyAttach-ttl-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create scratch dir");

    let stale = dir.join("stale.png");
    let fresh = dir.join("fresh.png");
    std::fs::write(&stale, b"stale").expect("write stale");
    std::fs::write(&fresh, b"fresh").expect("write fresh");

    // Age one file past the TTL by writing its mtime directly.
    let old_time = SystemTime::now() - Duration::from_secs(600);
    let f = std::fs::File::options().write(true).open(&stale).expect("open stale");
    f.set_modified(old_time).expect("set mtime");
    drop(f);

    crate::ffi::paste::purge_age_out(dir.clone(), Duration::from_secs(60));

    let stale_exists = stale.exists();
    let fresh_exists = fresh.exists();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(!stale_exists, "a file older than the TTL must be purged");
    assert!(fresh_exists, "a file inside the TTL must survive (it may still be in use)");
}

#[test]
fn test_auto_cleanup_at_threshold_100() {
    let hist = fill_and_trim_to(100, 150);
    assert_eq!(hist.len(), 100);
}

#[test]
fn test_auto_cleanup_at_threshold_500() {
    let hist = fill_and_trim_to(500, 750);
    assert_eq!(hist.len(), 500);
}

#[test]
fn test_auto_cleanup_at_threshold_1000() {
    let hist = fill_and_trim_to(1000, 1500);
    assert_eq!(hist.len(), 1000);
}

#[test]
fn test_auto_cleanup_at_threshold_2000() {
    let hist = fill_and_trim_to(2000, 3000);
    assert_eq!(hist.len(), 2000);
}

#[test]
fn test_auto_cleanup_at_threshold_3000() {
    let hist = fill_and_trim_to(3000, 4500);
    assert_eq!(hist.len(), 3000);
}

#[test]
fn test_auto_cleanup_at_threshold_5000() {
    let hist = fill_and_trim_to(5000, 7500);
    assert_eq!(hist.len(), 5000);
}

#[test]
fn test_auto_cleanup_keeps_newest() {
    let hist = fill_and_trim_to(10, 50);
    assert_eq!(hist.len(), 10);
    assert_eq!(hist[0].label(), "item-0049");
}

#[test]
fn test_auto_cleanup_removes_oldest() {
    let hist = fill_and_trim_to(10, 50);
    assert_eq!(hist[9].label(), "item-0040");
}

#[test]
fn test_auto_cleanup_no_trim_below_threshold() {
    let hist = fill_and_trim_to(100, 50);
    assert_eq!(hist.len(), 50);
}

#[test]
fn test_auto_cleanup_empty_history() {
    let hist = fill_and_trim_to(100, 0);
    assert!(hist.is_empty());
}

#[test]
fn test_auto_cleanup_exactly_at_threshold() {
    let hist = fill_and_trim_to(100, 100);
    assert_eq!(hist.len(), 100);
}

#[test]
fn test_trim_percent_0() {
    let hist = with_rows(100);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 0);
    assert_eq!(kept.len(), 100);
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_100() {
    let hist = with_rows(100);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 100);
    assert!(kept.is_empty());
    assert_eq!(removed.len(), 100);
}

#[test]
fn test_trim_percent_40() {
    let mut hist = Vec::new();
    for i in 0..100 {
        hist = add_to_history(hist, make_text(&format!("t-{:03}", i), i as u64));
    }
    assert_eq!(hist.len(), 100);
    assign_row_ids(&mut hist);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 60);
    assert_eq!(removed.len(), 40);
    assert_eq!(kept[0].label(), "t-099");
    assert_eq!(removed[0].label(), "t-039");
}

#[test]
fn test_trim_percent_50_even() {
    let hist = with_rows(50);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 50);
    assert_eq!(kept.len(), 25);
    assert_eq!(removed.len(), 25);
}

#[test]
fn test_trim_percent_ceil_small_count() {
    let hist = with_rows(3);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 1);
    assert_eq!(removed.len(), 2);
}

#[test]
fn test_trim_percent_empty() {
    let (kept, removed) = simulate_trim_oldest_percent(vec![], 40);
    assert!(kept.is_empty());
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_ceil_single_entry() {
    let mut hist = vec![make_text("only", 0)];
    assign_row_ids(&mut hist);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 1);
    assert!(kept.is_empty());
    assert_eq!(removed.len(), 1);
}

#[test]
fn test_trim_percent_all_thresholds_consistency() {
    for &threshold in &[100, 500, 1000, 2000, 3000, 5000] {
        let over = (threshold as f64 * 1.1) as usize;
        let mut hist = fill_and_trim_to(threshold, over);
        assert_eq!(hist.len(), threshold, "failed fill at threshold {}", threshold);
        assign_row_ids(&mut hist);
        let kept_count = threshold - ((threshold as f64 * 0.4).ceil()) as usize;
        let (kept, _) = simulate_trim_oldest_percent(hist, 40);
        assert_eq!(kept.len(), kept_count, "failed trim at threshold {}", threshold);
        hist = kept;
    }
}

#[test]
fn test_threshold_reduction_trims_history() {
    let mut hist: Vec<_> = (0..200).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    assert_eq!(hist.len(), 200);

    let new_threshold = 100usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert_eq!(hist.len(), 100);

    assert_eq!(hist[0].label(), "t-199");
    assert_eq!(hist[99].label(), "t-100");
}

#[test]
fn test_threshold_increase_preserves_all() {
    let mut hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    let new_threshold = 100usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert_eq!(hist.len(), 50);
}

#[test]
fn test_threshold_reduction_to_minimum() {
    let mut hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    let new_threshold = 0usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert!(hist.is_empty());
}

#[test]
fn test_trim_percent_40_preserves_favorites() {
    let mut hist = Vec::new();
    for i in 0..100 {
        hist = add_to_history(hist, make_text(&format!("t-{:03}", i), i as u64));
    }
    assert_eq!(hist.len(), 100);
    assign_row_ids(&mut hist);

    // Pick 4 favorites: the two oldest entries (at the tail), one in the middle, and newest (head).
    let fav_0 = hist[99].entry_id();
    let fav_1 = hist[98].entry_id();
    let fav_50 = hist[50].entry_id();
    let fav_new = hist[0].entry_id();
    let mut favorites = std::collections::HashSet::new();
    favorites.insert(fav_0);
    favorites.insert(fav_1);
    favorites.insert(fav_50);
    favorites.insert(fav_new);

    let (kept, removed) = simulate_trim_oldest_percent_with_favorites(hist, 40, &favorites);

    // Cleanable entries = 100 - 4 = 96.
    // 40% of 96 = ceil(38.4) = 39 removed.
    // Kept = 100 - 39 = 61.
    assert_eq!(removed.len(), 39);
    assert_eq!(kept.len(), 61);

    for &fav_id in &favorites {
        assert!(kept.iter().any(|e| e.entry_id() == fav_id), "favorite {fav_id} must be kept");
        assert!(!removed.iter().any(|e| e.entry_id() == fav_id), "favorite {fav_id} must not be removed");
    }
}

#[test]
fn test_trim_percent_all_favorited() {
    let mut hist = Vec::new();
    for i in 0..10 {
        hist = add_to_history(hist, make_text(&format!("t-fav-{:02}", i), i as u64));
    }
    assign_row_ids(&mut hist);
    let favorites: std::collections::HashSet<u64> = hist.iter().map(|e| e.entry_id()).collect();

    let (kept, removed) = simulate_trim_oldest_percent_with_favorites(hist, 40, &favorites);
    assert_eq!(kept.len(), 10);
    assert!(removed.is_empty());
}
