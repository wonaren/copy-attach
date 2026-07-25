//! CLI tool to generate stress-test data in the CopyAttach SQLite database.
//!
//! Usage:
//!   cargo run --bin stress-gen --features stress-test -- [options]
//!
//! Options:
//!   --count N      total entries (default: 10000)
//!   --text-ratio R text fraction 0.0–1.0 (default: 0.6)
//!   --seed N       deterministic seed (default: 42)
//!   --db-path PATH override default DB path
//!   --threshold N  cleanup threshold (default: 10000)
//!   --dry-run      print plan and exit without writing
//!   --report       print a detailed report after generation

/// Simple arg-parser (no dependency needed).
struct Args {
    count: usize,
    text_ratio: f64,
    seed: u64,
    db_path: String,
    threshold: usize,
    dry_run: bool,
    report: bool,
}

fn parse_args() -> Args {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let mut args = Args {
        count: 10000,
        text_ratio: 0.6,
        seed: 42,
        db_path: copy_attach::stress::default_db_path()
            .unwrap_or_else(|| "/tmp/copyattach_stress.db".to_string()),
        threshold: 10000,
        dry_run: false,
        report: false,
    };
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--count" => { i += 1; if i < raw.len() { args.count = raw[i].parse().ok().unwrap_or(10000); } }
            "--text-ratio" => { i += 1; if i < raw.len() { args.text_ratio = raw[i].parse().ok().unwrap_or(0.6); } }
            "--seed" => { i += 1; if i < raw.len() { args.seed = raw[i].parse().ok().unwrap_or(42); } }
            "--db-path" => { i += 1; if i < raw.len() { args.db_path = raw[i].clone(); } }
            "--threshold" => { i += 1; if i < raw.len() { args.threshold = raw[i].parse().ok().unwrap_or(10000); } }
            "--dry-run" => { args.dry_run = true; }
            "--report" => { args.report = true; }
            _ => {}
        }
        i += 1;
    }
    args
}

fn print_plan(args: &Args) {
    let text_count = (args.count as f64 * args.text_ratio) as usize;
    let image_count = args.count - text_count;
    let per_category_text = text_count / 5;
    let per_category_image = image_count / 5;

    println!("╔══════════════════════════════════════════════════════════╗");
    println!("║         CopyAttach Stress-Test Data Generator          ║");
    println!("╚══════════════════════════════════════════════════════════╝");
    println!();
    println!("  Database:    {}", args.db_path);
    println!("  Total:       {} entries", args.count);
    println!("  Text ratio:  {:.0}% → {} entries", args.text_ratio * 100.0, text_count);
    println!("  Image ratio: {:.0}% → {} entries", (1.0 - args.text_ratio) * 100.0, image_count);
    println!("  Seed:        {}", args.seed);
    println!("  Threshold:   {}", args.threshold);
    println!();
    println!("  ── Text Distribution ──");
    println!("    Short   (16–64 B):     {} entries", per_category_text);
    println!("    Medium  (256–1024 B):  {} entries", per_category_text);
    println!("    MedLong (4k–16k B):    {} entries", per_category_text);
    println!("    Long    (16k–32k B):   {} entries", per_category_text);
    println!("    XLong   (48k–64k B):   {} entries", text_count - per_category_text * 4);
    println!();
    println!("  ── Image Distribution ──");
    println!("    540p (960×540):        {} entries", per_category_image);
    println!("    1k   (1920×1080):      {} entries", per_category_image);
    println!("    2k   (2560×1440):      {} entries", per_category_image);
    println!("    4k   (3840×2160):      {} entries", per_category_image);
    println!("    8k   (7680×4320):      {} entries", image_count - per_category_image * 4);
    println!();
    println!("  Estimated DB size (rough):");
    let text_bytes =
        per_category_text * 40     // short: 40 avg
        + per_category_text * 640    // medium: 640 avg
        + per_category_text * 10000  // medlong: 10k avg
        + per_category_text * 24000  // long: 24k avg
        + (text_count - per_category_text * 4) * 56000; // xlong: 56k avg
    println!("    Text data:  ~{}", format_bytes(text_bytes));
    println!("    Image data: ~{} (simulated)", format_bytes(image_count * 200_000));
    println!();
}

fn format_bytes(bytes: usize) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        format!("{:.1} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if bytes >= 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{} B", bytes)
    }
}

fn main() {
    let args = parse_args();
    print_plan(&args);

    if args.dry_run {
        println!("  ── DRY RUN — no data written ──");
        return;
    }

    println!("  Generating data...");
    let stats = copy_attach::stress::inject_into_db(
        &args.db_path,
        args.count,
        args.text_ratio,
        args.seed,
        args.threshold,
    );

    println!("  ✓ Done in {}.{:03}s", stats.elapsed_ms / 1000, stats.elapsed_ms % 1000);
    println!("  Total inserted: {} entries ({} text, {} images)", stats.total, stats.texts, stats.images);
    println!("  DB file size:   {}", format_bytes(stats.db_size_bytes as usize));

    if args.report {
        println!();
        println!("  ── Detailed Report ──");
        println!("  Elapsed:        {}.{:03}s", stats.elapsed_ms / 1000, stats.elapsed_ms % 1000);
        println!("  Text entries:   {} total", stats.texts);
        println!("    Short:   {}", stats.text_sizes[0]);
        println!("    Medium:  {}", stats.text_sizes[1]);
        println!("    MedLong: {}", stats.text_sizes[2]);
        println!("    Long:    {}", stats.text_sizes[3]);
        println!("    XLong:   {}", stats.text_sizes[4]);
        println!("  Image entries:  {} total", stats.images);
        println!("    540p:  {}", stats.image_sizes[0]);
        println!("    1k:    {}", stats.image_sizes[1]);
        println!("    2k:    {}", stats.image_sizes[2]);
        println!("    4k:    {}", stats.image_sizes[3]);
        println!("    8k:    {}", stats.image_sizes[4]);
        println!("  Avg insert rate: {:.0} entries/s", stats.total as f64 / (stats.elapsed_ms as f64 / 1000.0));
    }
}
