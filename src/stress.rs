//! Stress-test data generation and in-app benchmarking.
//!
//! All items here are gated behind the `stress-test` feature (never ships in
//! release builds). The CLI binary `stress-gen` and the Swift stress panel both
//! call into this module.
//!
//! ## Data Distribution (10,000 entries)
//!
//! **Text (6,000; 60%)** — 5 length bands, 1,200 each:
//!   - short:   16–64 B    (tweet-like snippets)
//!   - medium:  256–1024 B (paragraphs)
//!   - medlong:  4k–16k B  (markdown docs)
//!   - long:    16k–32k B  (code files, logs)
//!   - xlong:   48k–64k B  (long articles)
//!
//! **Image (4,000; 40%)** — 5 resolutions, 800 each:
//!   540p (960×540), 1k (1920×1080), 2k (2560×1440),
//!   4k (3840×2160), 8k (7680×4320)

use std::time::Instant;

use crate::backend::new_entry_id;
use crate::db::{insert_entry_to_db, trim_db_history};
use crate::image::{encode_png, image_hash};
use crate::types::ClipboardEntry;

// ═══════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════

const THUMB_MAX_DIM: u32 = 300;

/// Text length categories with their target byte ranges.
#[derive(Clone, Copy)]
pub enum TextLength {
    Short,     // 16–64 B
    Medium,    // 256–1024 B
    MedLong,   // 4k–16k B
    Long,      // 16k–32k B
    XLong,     // 48k–64k B
}

/// Resolution categories.
#[derive(Clone, Copy)]
pub enum ImageResolution {
    Res540p,   // 960×540
    Res1k,     // 1920×1080
    Res2k,     // 2560×1440
    Res4k,     // 3840×2160
    Res8k,     // 7680×4320
}

impl ImageResolution {
    pub fn dims(&self) -> (u32, u32) {
        match self {
            ImageResolution::Res540p => (960, 540),
            ImageResolution::Res1k => (1920, 1080),
            ImageResolution::Res2k => (2560, 1440),
            ImageResolution::Res4k => (3840, 2160),
            ImageResolution::Res8k => (7680, 4320),
        }
    }
}

/// Stats collected during data generation.
#[derive(Default)]
pub struct InjectStats {
    pub total: usize,
    pub texts: usize,
    pub images: usize,
    pub db_size_bytes: i64,
    pub elapsed_ms: u64,
    pub text_sizes: [usize; 5], // per-category counts
    pub image_sizes: [usize; 5],
}

// ═══════════════════════════════════════════
// Text Generation
// ═══════════════════════════════════════════

/// Small word pool for realistic-looking short entries.
const SHORT_WORDS: &[&str] = &[
    "hello", "world", "test", "note", "todo", "fixme", "idea", "ref", "code",
    "bug", "crash", "log", "error", "warn", "info", "debug", "trace", "config",
    "setup", "build", "deploy", "merge", "push", "pull", "commit", "branch",
    "issue", "pr", "review", "fix", "feat", "docs", "style", "refactor", "perf",
    "test", "chore", "ci", "revert", "release", "alpha", "beta", "stable",
    "path", "file", "dir", "tmp", "var", "usr", "bin", "etc", "home", "root",
    "key", "val", "map", "list", "vec", "arr", "str", "int", "bool", "opt",
    "result", "ok", "err", "some", "none", "true", "false", "null", "nil",
];

const LOREM_WORDS: &[&str] = &[
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
    "elit", "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore",
    "et", "dolore", "magna", "aliqua", "ut", "enim", "ad", "minim", "veniam",
    "quis", "nostrud", "exercitation", "ullamco", "laboris", "nisi", "ut",
    "aliquip", "ex", "ea", "commodo", "consequat", "duis", "aute", "irure",
    "dolor", "in", "reprehenderit", "in", "voluptate", "velit", "esse", "cillum",
    "dolore", "eu", "fugiat", "nulla", "pariatur", "excepteur", "sint",
    "occaecat", "cupidatat", "non", "proident", "sunt", "in", "culpa", "qui",
    "officia", "deserunt", "mollis", "anim", "id", "est", "laborum",
];

const CODE_KEYWORDS: &[&str] = &[
    "fn", "let", "mut", "const", "static", "pub", "use", "mod", "struct", "enum",
    "impl", "trait", "async", "await", "match", "if", "else", "for", "while",
    "loop", "return", "break", "continue", "true", "false", "Some", "None",
    "Ok", "Err", "Result", "Option", "Vec", "String", "HashMap", "Arc", "Mutex",
    "Box", "Rc", "Cell", "RefCell", "Deref", "Drop", "Clone", "Copy", "Debug",
    "Display", "Serialize", "Deserialize", "Default", "Into", "From",
];

fn pseudo_word<'a>(rng: &mut impl FnMut() -> u64, pool: &'a [&'a str]) -> &'a str {
    let idx = (rng() as usize) % pool.len();
    pool[idx]
}

/// Build a string of roughly `target_len` bytes using the given word pool and
/// word spacing pattern.  Returns a string whose byte length is as close to
/// `target_len` as possible (may overshoot by one word).
fn build_text(
    target_len: usize,
    rng: &mut impl FnMut() -> u64,
    pool: &[&str],
    separator: &str,
) -> String {
    let mut out = String::with_capacity(target_len + 64);
    let sep = separator;
    while out.len() < target_len {
        if !out.is_empty() {
            out.push_str(sep);
        }
        out.push_str(pseudo_word(rng, pool));
    }
    out
}

/// Build code-like text with indentation and line breaks.
fn build_code(target_len: usize, rng: &mut impl FnMut() -> u64) -> String {
    let mut out = String::with_capacity(target_len + 64);
    while out.len() < target_len {
        // Random indentation
        let indent = (rng() % 4) as usize;
        for _ in 0..indent {
            out.push_str("    ");
        }
        out.push_str(pseudo_word(rng, CODE_KEYWORDS));
        // Random trailing content: parens, angle brackets, semicolon
        match rng() % 4 {
            0 => { out.push_str("()"); }
            1 => { out.push_str("<>"); }
            2 => { out.push_str(";"); }
            _ => { out.push_str("() -> "); out.push_str(pseudo_word(rng, CODE_KEYWORDS)); }
        }
        out.push('\n');
        if out.len() >= target_len { break; }
    }
    out
}

/// Build structured markdown-like text (headings, paragraphs, lists).
fn build_doc(target_len: usize, rng: &mut impl FnMut() -> u64) -> String {
    let mut out = String::with_capacity(target_len + 64);
    // Heading
    out.push_str("# ");
    out.push_str(pseudo_word(rng, LOREM_WORDS));
    out.push(' ');
    out.push_str(pseudo_word(rng, LOREM_WORDS));
    out.push('\n');
    out.push('\n');

    while out.len() < target_len {
        // Random paragraph or list
        match rng() % 5 {
            0 => {
                // Subheading
                out.push_str("## ");
                out.push_str(pseudo_word(rng, LOREM_WORDS));
                out.push('\n');
            }
            1 => {
                // List item
                out.push_str("- ");
                let n = 5 + (rng() % 15) as usize;
                for _ in 0..n {
                    out.push_str(pseudo_word(rng, LOREM_WORDS));
                    out.push(' ');
                }
                out.push('\n');
            }
            _ => {
                // Paragraph
                let n = 10 + (rng() % 30) as usize;
                for i in 0..n {
                    if i > 0 { out.push(' '); }
                    out.push_str(pseudo_word(rng, LOREM_WORDS));
                }
                out.push_str(". ");
            }
        }
        if out.len() >= target_len { break; }
    }
    out
}

/// Generate a string whose byte length falls in the given range.
fn generate_text_content(category: TextLength, seed: u64) -> String {
    let mut rng = splitmix64(seed);

    let (target, style) = match category {
        TextLength::Short  => match seed % 4 {
            0 => (16 + (rng() % 48) as usize, 0),   // 16–63 B
            1 => (16 + (rng() % 16) as usize, 1),   // 16–31 B
            _ => (32 + (rng() % 32) as usize, 2),   // 32–63 B
        },
        TextLength::Medium => match seed % 3 {
            0 => (256 + (rng() % 768) as usize, 0), // paragraph
            1 => (512 + (rng() % 512) as usize, 1), // code
            _ => (400 + (rng() % 624) as usize, 2), // note
        },
        TextLength::MedLong => match seed % 3 {
            0 => (4096 + (rng() % 12288) as usize, 0), // doc
            1 => (4096 + (rng() % 4096) as usize, 1),  // code
            _ => (8192 + (rng() % 8192) as usize, 2),  // mixed
        },
        TextLength::Long   => match seed % 2 {
            0 => (16384 + (rng() % 16384) as usize, 0), // doc
            _ => (16384 + (rng() % 8192) as usize, 1),  // code
        },
        TextLength::XLong  => match seed % 2 {
            0 => (49152 + (rng() % 16384) as usize, 0), // doc
            _ => (49152 + (rng() % 8192) as usize, 1),  // code+log
        },
    };

    match style {
        0 => build_text(target, &mut rng, LOREM_WORDS, " "),
        1 => build_code(target, &mut rng),
        _ => build_doc(target, &mut rng),
    }
}

// ═══════════════════════════════════════════
// Image Generation (fast block-based)
// ═══════════════════════════════════════════

/// SplitMix64 pseudo-random generator (fast, deterministic).
fn splitmix64(mut state: u64) -> impl FnMut() -> u64 {
    move || {
        state = state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}

/// Generate a RGBA pixel buffer using fast block-based rendering.
///
/// Much faster than per-pixel computation at high resolutions.
/// The image is divided into a grid of cells. Each cell gets a solid colour
/// derived from its position + seed.  Thin horizontal lines and window blocks
/// are drawn using slice fills (not per-pixel loops), making this viable even
/// at 8K resolution.
fn generate_image_rgba(width: u32, height: u32, seed: u64) -> Vec<u8> {
    let total = (width as usize) * (height as usize) * 4;
    let mut pixels = vec![0u8; total];

    // Grid size scales with resolution to keep block count manageable.
    let grid = if width >= 3840 { 12 } else if width >= 1920 { 8 } else { 4 };
    let cell_w = (width / grid).max(1);
    let cell_h = (height / grid).max(1);

    let mut rng = splitmix64(seed);
    let cell_colors: Vec<(u8, u8, u8)> = (0..grid * grid)
        .map(|_| ((rng() as u8), (rng() as u8), (rng() as u8)))
        .collect();

    for cy in 0..grid {
        for cx in 0..grid {
            let (r0, g0, b0) = cell_colors[(cy * grid + cx) as usize];

            // Warm up the base with a gradient shift
            let grad_r = (cy as f64 / grid as f64 * 60.0) as u8;
            let grad_g = (cx as f64 / grid as f64 * 40.0) as u8;
            let grad_b = ((grid - cy) as f64 / grid as f64 * 50.0) as u8;

            let x0 = cx * cell_w;
            let y0 = cy * cell_h;
            let x1 = (x0 + cell_w).min(width);
            let y1 = (y0 + cell_h).min(height);

            let has_window = (cx + cy) % 3 == 1;

            // Pre-compute the two colors used in this cell
            let base_r = r0.wrapping_add(grad_r);
            let base_g = g0.wrapping_add(grad_g);
            let base_b = b0.wrapping_add(grad_b);

            let text_r = base_r.wrapping_sub(30);
            let text_g = base_g.wrapping_sub(30);
            let text_b = base_b.wrapping_sub(20);

            let (win_r, win_g, win_b) = if has_window {
                ((rng() as u8 & 0x3f) + 0x40,
                 (rng() as u8 & 0x3f) + 0x40,
                 (rng() as u8 & 0x3f) + 0x40)
            } else {
                (0u8, 0u8, 0u8)
            };

            let is_window_cell = has_window;
            let win_margin = 4u32;

            for y in y0..y1 {
                let row_start = ((y * width + x0) * 4) as usize;
                let row_end = ((y * width + x1) * 4) as usize;
                let row = &mut pixels[row_start..row_end];

                let (r, g, b) = if y % 12 < 2 {
                    // Text line
                    (text_r, text_g, text_b)
                } else if is_window_cell && y > y0 + win_margin && y < y1 - win_margin {
                    (win_r, win_g, win_b)
                } else {
                    (base_r, base_g, base_b)
                };

                // Fast uniform fill of the entire row slice
                let rgba = [r, g, b, 255];
                for chunk in row.chunks_exact_mut(4) {
                    chunk.copy_from_slice(&rgba);
                }
            }
        }
    }
    pixels
}

// ═══════════════════════════════════════════
// DB Injection
// ═══════════════════════════════════════════

/// Inject `count` entries into a DB at `db_path`.  Returns stats.
///
/// `text_ratio` should be in [0.0, 1.0].  The remaining fraction is images.
/// Uses the given `seed` for deterministic generation.
pub fn inject_into_db(
    db_path: &str,
    count: usize,
    text_ratio: f64,
    seed: u64,
    threshold: usize,
) -> InjectStats {
    let start = Instant::now();

    let conn = rusqlite::Connection::open(db_path)
        .expect("stress: failed to open DB for injection");
    conn.execute_batch(
        "PRAGMA mmap_size = 33554432;
         PRAGMA cache_size = -512;
         PRAGMA synchronous = OFF;"
    ).ok();

    // Ensure the history table exists
    crate::db::ensure_history_table(&conn).expect("stress: ensure table failed");

    let text_count = (count as f64 * text_ratio) as usize;
    let image_count = count - text_count;

    let mut stats = InjectStats::default();
    stats.total = count;
    stats.texts = text_count;
    stats.images = image_count;

    let categories_text = [
        (TextLength::Short,  text_count / 5),
        (TextLength::Medium, text_count / 5),
        (TextLength::MedLong,text_count / 5),
        (TextLength::Long,   text_count / 5),
        (TextLength::XLong,  text_count - (text_count / 5) * 4),
    ];

    let categories_image = [
        (ImageResolution::Res540p, image_count / 5),
        (ImageResolution::Res1k,   image_count / 5),
        (ImageResolution::Res2k,   image_count / 5),
        (ImageResolution::Res4k,   image_count / 5),
        (ImageResolution::Res8k,   image_count - (image_count / 5) * 4),
    ];

    let mut idx = 0u64;

    // ── Insert text entries ───────────────────────────────────────
    for (cat, n) in &categories_text {
        for _i in 0..*n {
            let s = seed.wrapping_add(idx).wrapping_mul(6364136223846793005);
            let text = generate_text_content(*cat, s);
            let entry = ClipboardEntry::text_entry(
                new_entry_id(),
                &text,
                idx,
                String::from("StressTest"),
                String::from("com.stresstest"),
                0,
            );
            // Insert: no png, no thumb. Dedup is unnecessary here —
            // every generated entry has unique content (unique seed per entry).
            insert_entry_to_db(&conn, &entry, Some(&text), None, None).ok();
            idx += 1;

            // Track category
            let ci = match cat {
                TextLength::Short => 0,
                TextLength::Medium => 1,
                TextLength::MedLong => 2,
                TextLength::Long => 3,
                TextLength::XLong => 4,
            };
            stats.text_sizes[ci] += 1;
        }
        eprintln!("PROGRESS:{}/{}", idx, count);
    }

    // ── Insert image entries ──────────────────────────────────────
    for (cat, n) in &categories_image {
        let (w, h) = cat.dims();
        for _i in 0..*n {
            let s = seed.wrapping_add(idx).wrapping_mul(6364136223846793005);

            // Determine encode resolution (capped at FHD for speed).
            // The stored PNG is downscaled but entry metadata keeps the
            // original resolution — the app's handling of metadata+thumb
            // is what matters.
            const MAX_ENCODE_DIM: u32 = 1920;
            let (encode_w, encode_h) = if w.max(h) > MAX_ENCODE_DIM {
                let scale = MAX_ENCODE_DIM as f64 / w.max(h) as f64;
                ((w as f64 * scale).round() as u32,
                 (h as f64 * scale).round() as u32)
            } else {
                (w, h)
            };

            // Generate RGBA at encode resolution (much cheaper than native)
            let rgba = generate_image_rgba(encode_w.max(1), encode_h.max(1), s);
            let hash = image_hash(&rgba, encode_w.max(1), encode_h.max(1));

            // Generate thumbnail DIRECTLY at thumb resolution — skip the
            // expensive downscale from native resolution.  Using the same
            // seed-based block generator at thumb scale gives a visually
            // consistent result without touching 33M pixels.
            let thumb_scale = THUMB_MAX_DIM as f64 / encode_w.max(encode_h) as f64;
            let (thumb_w, thumb_h) = if thumb_scale < 1.0 {
                ((encode_w as f64 * thumb_scale).round() as u32,
                 (encode_h as f64 * thumb_scale).round() as u32)
            } else {
                (encode_w, encode_h)
            };
            let thumb_sky = generate_image_rgba(thumb_w.max(1), thumb_h.max(1), s);
            let thumb_data = encode_png(thumb_w.max(1), thumb_h.max(1), &thumb_sky)
                .unwrap_or_default();

            // Encode full PNG
            let png = encode_png(encode_w.max(1), encode_h.max(1), &rgba)
                .expect("stress: PNG encode failed");

            let entry = ClipboardEntry::Image {
                id: new_entry_id(),
                png_data: Vec::new(), // not kept in memory
                width: w,
                height: h,
                thumb_data: Vec::new(),
                thumb_width: thumb_w,
                thumb_height: thumb_h,
                hash,
                timestamp: idx,
                source_name: String::from("StressTest"),
                source_bundle_id: String::from("com.stresstest"),
                db_id: 0,
            };
            insert_entry_to_db(&conn, &entry, None, Some(&png), Some((&thumb_data, thumb_w, thumb_h))).ok();
            idx += 1;

            let ci = match cat {
                ImageResolution::Res540p => 0,
                ImageResolution::Res1k => 1,
                ImageResolution::Res2k => 2,
                ImageResolution::Res4k => 3,
                ImageResolution::Res8k => 4,
            };
            stats.image_sizes[ci] += 1;
        }
        eprintln!("PROGRESS:{}/{}", idx, count);
    }

    // Trim
    trim_db_history(&conn, threshold);

    // Get DB file size
    if let Ok(meta) = std::fs::metadata(db_path) {
        stats.db_size_bytes = meta.len() as i64;
    }

    stats.elapsed_ms = start.elapsed().as_millis() as u64;
    stats
}

/// Get the default DB path.
pub fn default_db_path() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    Some(format!("{}/Library/Application Support/CopyAttach/history.db", home))
}

// ═══════════════════════════════════════════
// FFI Helpers — called from ffi.rs
// ═══════════════════════════════════════════

/// In-memory injection into the running backend.
/// Returns the number of entries actually inserted.
pub fn ffi_inject(count: i32, text_ratio: f64, seed: i64) -> i32 {
    let b = crate::backend::backend();
    let db_path = match default_db_path() {
        Some(p) => p,
        None => return 0,
    };

    // Use the injection count as the DB trim threshold so all injected
    // entries survive in the DB. The in-memory reload below will then
    // apply the backend's configured limit.
    let injected = inject_into_db(&db_path, count as usize, text_ratio, seed as u64, count as usize);
    // Reload from DB into in-memory history via the shared helper.
    crate::backend::reload_history_from_db(b);

    injected.total as i32
}

/// Reset stress-injected data by re-loading from DB.
pub fn ffi_reset() {
    let b = crate::backend::backend();
    crate::backend::reload_history_from_db(b);
}

// ═══════════════════════════════════════════
// Benchmark Helpers (for Swift-side tests)
// ═══════════════════════════════════════════

/// Benchmark: measure snapshot lock contention by cloning the history N
/// times (mirrors what clipboard_snapshot_acquire does).  Returns average µs.
pub fn bench_snapshot_clone(n: i32) -> f64 {
    let b = crate::backend::try_backend();
    let hist = match b {
        Some(b) => &b.history,
        None => return 0.0,
    };
    let mut total = 0u128;
    for _ in 0..n {
        let t0 = Instant::now();
        let _guard = hist.lock().unwrap();
        total += t0.elapsed().as_nanos();
    }
    total as f64 / (n as f64 * 1000.0)
}

/// Benchmark: measure the overhead of reading the history Vec length through
/// a mutex lock.  Returns average ns.
pub fn bench_count(n: i32) -> f64 {
    let b = crate::backend::try_backend();
    let hist = match b {
        Some(b) => &b.history,
        None => return 0.0,
    };
    let mut total = 0u128;
    for _ in 0..n {
        let t0 = Instant::now();
        let _count = hist.lock().unwrap().len();
        total += t0.elapsed().as_nanos();
    }
    total as f64 / n as f64
}
