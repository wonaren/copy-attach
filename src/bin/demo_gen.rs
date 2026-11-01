use std::path::PathBuf;

struct Args {
    db_path: PathBuf,
    images_dir: PathBuf,
    force: bool,
}

fn parse_args() -> Args {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let mut args = Args {
        db_path: PathBuf::from("demo-data/history.db"),
        images_dir: PathBuf::from("demo-data/images"),
        force: false,
    };
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--db-path" => {
                i += 1;
                match raw.get(i) {
                    Some(p) => args.db_path = PathBuf::from(p),
                    None => usage_exit("--db-path needs a value"),
                }
            }
            "--images-dir" => {
                i += 1;
                match raw.get(i) {
                    Some(p) => args.images_dir = PathBuf::from(p),
                    None => usage_exit("--images-dir needs a value"),
                }
            }
            "--force" => args.force = true,
            "-h" | "--help" => {
                println!("usage: demo-gen [--db-path PATH] [--images-dir DIR] [--force]");
                std::process::exit(0);
            }
            other => usage_exit(&format!("unknown argument: {other}")),
        }
        i += 1;
    }
    args
}

fn usage_exit(message: &str) -> ! {
    eprintln!("demo-gen: {message}");
    eprintln!("usage: demo-gen [--db-path PATH] [--images-dir DIR] [--force]");
    std::process::exit(2);
}

fn main() {
    let args = parse_args();
    if args.force {
        copy_attach::demo::remove_db_files(&args.db_path);
    }
    match copy_attach::demo::generate(&args.db_path, &args.images_dir) {
        Ok(summary) => {
            println!(
                "demo dataset: {} texts + {} images, {:.1} KB, generated {}",
                summary.texts,
                summary.images,
                summary.bytes as f64 / 1024.0,
                summary.generated_at,
            );
            println!("written to: {}", args.db_path.display());
        }
        Err(e) => {
            eprintln!("demo-gen: {e}");
            std::process::exit(1);
        }
    }
}
