//! Standalone benchmark binary for CopyAttach performance metrics.
//! Usage: cargo run --bin bench --features stress-test

use std::sync::{Arc, Mutex};
use std::time::Instant;

fn main() {
    println!("CopyAttach Performance Benchmarks");
    println!("==================================\n");

    // ── 1. Snapshot clone benchmark ──
    bench_snapshot();

    // ── 2. Count lock benchmark ──
    bench_count();

    // ── 3. Image encode/decode benchmark ──
    bench_images();

    // ── 4. Search/filter benchmark ──
    bench_search();

    println!("==================================");
    println!("Benchmarks complete.");
}

fn bench_snapshot() {
    println!("── Snapshot Clone (simulates clipboard_snapshot_acquire) ──");

    for &size in &[100, 1000, 5000, 10000] {
        let dummy = vec![0u64; size];
        let history: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(dummy));

        let iterations = 1000;
        let start = Instant::now();
        for _ in 0..iterations {
            let _snap = history.lock().unwrap().clone();
        }
        let elapsed = start.elapsed();
        let avg_us = elapsed.as_nanos() as f64 / iterations as f64 / 1000.0;

        println!("  {:>5} entries: {:>8.2} µs avg ({} iterations)", size, avg_us, iterations);
    }
    println!();
}

fn bench_count() {
    println!("── Count Lock (simulates clipboard_get_count) ──");

    for &size in &[100, 1000, 5000, 10000] {
        let dummy = vec![0u64; size];
        let history: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(dummy));

        let iterations = 10000;
        let start = Instant::now();
        for _ in 0..iterations {
            let _len = history.lock().unwrap().len();
        }
        let elapsed = start.elapsed();
        let avg_ns = elapsed.as_nanos() as f64 / iterations as f64;

        println!("  {:>5} entries: {:>8.1} ns avg ({} iterations)", size, avg_ns, iterations);
    }
    println!();
}

// ── Inlined image code (avoids making crate internals pub) ──

fn splitmix64(mut state: u64) -> impl FnMut() -> u64 {
    move || {
        state = state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}

fn bench_images() {
    println!("── Image Encode/Decode (image crate, PNG) ──");

    let resolutions: &[(u32, u32, &str)] = &[
        (960, 540, "540p"),
        (1920, 1080, "FHD"),
        (2560, 1440, "2K"),
        (3840, 2160, "4K"),
    ];

    for &(w, h, label) in resolutions {
        let rgba = make_test_rgba(w, h, 42);

        let encode_start = Instant::now();
        let png = encode_png(w, h, &rgba);
        let encode_ms = encode_start.elapsed().as_secs_f64() * 1000.0;

        let decode_start = Instant::now();
        let _ = decode_png(&png);
        let decode_ms = decode_start.elapsed().as_secs_f64() * 1000.0;

        println!(
            "  {:>4} {}x{}: encode {:>7.1}ms | decode {:>7.1}ms | raw {:.1}MB -> PNG {:.0}KB",
            label, w, h, encode_ms, decode_ms,
            rgba.len() as f64 / 1_048_576.0,
            png.len() as f64 / 1024.0
        );
    }

    println!();
    println!("  -- Thumbnail (display box, generated at thumb size) --");
    for &(w, h, label) in resolutions {
        // Mirrors image::THUMB_BOX_W/H (this binary inlines image code).
        const BOX_W: u32 = 460 * 2;
        const BOX_H: u32 = 100 * 2;
        let (tw, th) = if w <= BOX_W && h <= BOX_H {
            (w, h)
        } else {
            let scale = (BOX_W as f64 / w as f64)
                .min(BOX_H as f64 / h as f64)
                .min(1.0);
            ((w as f64 * scale).round() as u32, (h as f64 * scale).round() as u32)
        };

        let t0 = Instant::now();
        let thumb_rgba = make_test_rgba(tw, th, 42);
        let thumb_png = encode_png(tw, th, &thumb_rgba);
        let gen_ms = t0.elapsed().as_secs_f64() * 1000.0;

        let t0 = Instant::now();
        let _ = decode_png(&thumb_png);
        let decode_ms = t0.elapsed().as_secs_f64() * 1000.0;

        println!(
            "  {:>4} -> {}x{}: gen+encode {:>7.1}ms | decode {:>7.1}ms | PNG {:.0}KB",
            label, tw, th, gen_ms, decode_ms,
            thumb_png.len() as f64 / 1024.0
        );
    }
    println!();
}

fn make_test_rgba(width: u32, height: u32, seed: u64) -> Vec<u8> {
    let total = (width as usize) * (height as usize) * 4;
    let mut pixels = vec![0u8; total];

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
            let grad_r = (cy as f64 / grid as f64 * 60.0) as u8;
            let grad_g = (cx as f64 / grid as f64 * 40.0) as u8;
            let grad_b = ((grid - cy) as f64 / grid as f64 * 50.0) as u8;

            let x0 = cx * cell_w;
            let y0 = cy * cell_h;
            let x1 = (x0 + cell_w).min(width);
            let y1 = (y0 + cell_h).min(height);

            let base_r = r0.wrapping_add(grad_r);
            let base_g = g0.wrapping_add(grad_g);
            let base_b = b0.wrapping_add(grad_b);
            let text_r = base_r.wrapping_sub(30);
            let text_g = base_g.wrapping_sub(30);
            let text_b = base_b.wrapping_sub(20);

            let has_window = (cx + cy) % 3 == 1;
            let (win_r, win_g, win_b) = if has_window {
                ((rng() as u8 & 0x3f) + 0x40,
                 (rng() as u8 & 0x3f) + 0x40,
                 (rng() as u8 & 0x3f) + 0x40)
            } else { (0, 0, 0) };
            let win_margin = 4u32;

            for y in y0..y1 {
                let row_start = ((y * width + x0) * 4) as usize;
                let row_end = ((y * width + x1) * 4) as usize;
                let row = &mut pixels[row_start..row_end];

                let (r, g, b) = if y % 12 < 2 {
                    (text_r, text_g, text_b)
                } else if has_window && y > y0 + win_margin && y < y1 - win_margin {
                    (win_r, win_g, win_b)
                } else {
                    (base_r, base_g, base_b)
                };

                let rgba = [r, g, b, 255];
                let (chunks, _) = row.as_chunks_mut::<4>();
                for chunk in chunks {
                    chunk.copy_from_slice(&rgba);
                }
            }
        }
    }
    pixels
}

fn encode_png(width: u32, height: u32, rgba: &[u8]) -> Vec<u8> {
    use image::codecs::png::PngEncoder;
    use image::{ExtendedColorType, ImageEncoder};
    let mut buf = Vec::new();
    let encoder = PngEncoder::new(&mut buf);
    encoder
        .write_image(rgba, width, height, ExtendedColorType::Rgba8)
        .unwrap();
    buf
}

fn decode_png(data: &[u8]) -> (Vec<u8>, u32, u32) {
    let img = image::load_from_memory(data).unwrap();
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    (rgba.into_raw(), w, h)
}

fn bench_search() {
    println!("── CJK Search Filter (10,000 entries substring scan) ──");

    let words = &[
        "hello", "world", "rust", "swift", "macos", "clipboard", "paste",
        "测试", "压力", "剪贴板", "管理", "性能", "代码", "lorem", "ipsum", "dolor",
        "config", "setup", "build", "deploy", "merge", "error", "debug", "todo",
        "東京", "京都", "大阪", "天気", "画面", "設定",
    ];

    let mut rng_state = 42u64;
    let mut rng = || {
        rng_state = rng_state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = rng_state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    };

    let items: Vec<String> = (0..10000)
        .map(|_| {
            let n = 3 + (rng() % 15) as usize;
            let mut s = String::with_capacity(n * 10);
            for _ in 0..n {
                s.push_str(words[(rng() as usize) % words.len()]);
                s.push(' ');
            }
            s
        })
        .collect();

    let queries = &["rust", "swift", "测试", "clipboard", "画面"];
    for query in queries {
        let start = Instant::now();
        let count = items.iter().filter(|item| item.contains(query)).count();
        let elapsed_us = start.elapsed().as_nanos() as f64 / 1000.0;

        println!("  \"{}\": {} matches in {:.1} µs", query, count, elapsed_us);
    }

    println!();
    println!("  -- Full scan (worst-case, rare grapheme) --");
    let start = Instant::now();
    let count = items.iter().filter(|item| item.contains("京都")).count();
    let elapsed_us = start.elapsed().as_nanos() as f64 / 1000.0;
    println!("  \"京都\": {} matches in {:.1} µs over 10,000 items", count, elapsed_us);

    println!();
}
