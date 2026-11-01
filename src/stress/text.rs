use super::splitmix64;
use super::TextLength;

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

fn build_code(target_len: usize, rng: &mut impl FnMut() -> u64) -> String {
    let mut out = String::with_capacity(target_len + 64);
    while out.len() < target_len {
        let indent = (rng() % 4) as usize;
        for _ in 0..indent {
            out.push_str("    ");
        }
        out.push_str(pseudo_word(rng, CODE_KEYWORDS));
        match rng() % 4 {
            0 => { out.push_str("()"); }
            1 => { out.push_str("<>"); }
            2 => { out.push(';'); }
            _ => { out.push_str("() -> "); out.push_str(pseudo_word(rng, CODE_KEYWORDS)); }
        }
        out.push('\n');
        if out.len() >= target_len { break; }
    }
    out
}

fn build_doc(target_len: usize, rng: &mut impl FnMut() -> u64) -> String {
    let mut out = String::with_capacity(target_len + 64);
    out.push_str("# ");
    out.push_str(pseudo_word(rng, LOREM_WORDS));
    out.push(' ');
    out.push_str(pseudo_word(rng, LOREM_WORDS));
    out.push('\n');
    out.push('\n');

    while out.len() < target_len {
        match rng() % 5 {
            0 => {
                out.push_str("## ");
                out.push_str(pseudo_word(rng, LOREM_WORDS));
                out.push('\n');
            }
            1 => {
                out.push_str("- ");
                let n = 5 + (rng() % 15) as usize;
                for _ in 0..n {
                    out.push_str(pseudo_word(rng, LOREM_WORDS));
                    out.push(' ');
                }
                out.push('\n');
            }
            _ => {
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

pub(super) fn generate_text_content(category: TextLength, seed: u64) -> String {
    let mut rng = splitmix64(seed);

    let (target, style) = match category {
        TextLength::Short  => match seed % 4 {
            0 => (16 + (rng() % 48) as usize, 0),
            1 => (16 + (rng() % 16) as usize, 1),
            _ => (32 + (rng() % 32) as usize, 2),
        },
        TextLength::Medium => match seed % 3 {
            0 => (256 + (rng() % 768) as usize, 0),
            1 => (512 + (rng() % 512) as usize, 1),
            _ => (400 + (rng() % 624) as usize, 2),
        },
        TextLength::MedLong => match seed % 3 {
            0 => (4096 + (rng() % 12288) as usize, 0),
            1 => (4096 + (rng() % 4096) as usize, 1),
            _ => (8192 + (rng() % 8192) as usize, 2),
        },
        TextLength::Long   => match seed % 2 {
            0 => (16384 + (rng() % 16384) as usize, 0),
            _ => (16384 + (rng() % 8192) as usize, 1),
        },
        TextLength::XLong  => match seed % 2 {
            0 => (49152 + (rng() % 16384) as usize, 0),
            _ => (49152 + (rng() % 8192) as usize, 1),
        },
    };

    match style {
        0 => build_text(target, &mut rng, LOREM_WORDS, " "),
        1 => build_code(target, &mut rng),
        _ => build_doc(target, &mut rng),
    }
}
