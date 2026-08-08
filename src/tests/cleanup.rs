// Auto-cleanup threshold, trim-oldest-percent, and dynamic threshold tests.

use crate::history::add_to_history;
use super::{fill_and_trim_to, make_text, simulate_trim_oldest_percent};

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
    let hist: Vec<_> = (0..100).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 0);
    assert_eq!(kept.len(), 100);
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_100() {
    let hist: Vec<_> = (0..100).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
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
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 60);
    assert_eq!(removed.len(), 40);
    assert_eq!(kept[0].label(), "t-099");
    assert_eq!(removed[0].label(), "t-039");
}

#[test]
fn test_trim_percent_50_even() {
    let hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 50);
    assert_eq!(kept.len(), 25);
    assert_eq!(removed.len(), 25);
}

#[test]
fn test_trim_percent_ceil_small_count() {
    let hist: Vec<_> = (0..3).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
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
    let hist = vec![make_text("only", 0)];
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
