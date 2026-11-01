use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use crate::db::{ensure_history_table, set_favorite, insert_entry_to_db, METADATA_VERSION};
use crate::image::{create_thumbnail_fast, encode_png, image_hash};
use crate::types::ClipboardEntry;

pub const MARKER_KEY: &str = "demo_dataset";

struct DemoText {
    ago: u64,
    source: &'static str,
    bundle: &'static str,
    favorite: bool,
    text: &'static str,
}

struct DemoImage {
    ago: u64,
    source: &'static str,
    bundle: &'static str,
    favorite: bool,
    file: &'static str,
    url: &'static str,
}

const TEXTS: &[DemoText] = &[
    DemoText {
        ago: 45,
        source: "Visual Studio Code",
        bundle: "com.microsoft.VSCode",
        favorite: false,
        text: "#[derive(Debug, Clone)]\nstruct RetryPolicy {\n    max_attempts: u32,\n    base_delay: Duration,\n}\n\nimpl RetryPolicy {\n    fn delay_for(&self, attempt: u32) -> Duration {\n        self.base_delay * 2u32.pow(attempt.saturating_sub(1))\n    }\n}",
    },
    DemoText {
        ago: 130,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: true,
        text: "https://github.com/wonaren/copy-attach",
    },
    DemoText {
        ago: 260,
        source: "Terminal",
        bundle: "com.apple.Terminal",
        favorite: false,
        text: "git fetch --all --prune\ngit rebase --autosquash --interactive origin/main\ngit log --oneline --graph --decorate -20",
    },
    DemoText {
        ago: 520,
        source: "WeChat",
        bundle: "com.tencent.xinWeChat",
        favorite: false,
        text: "收到，我这边下午三点前把设计稿和切图一起发你，辛苦先按 320pt 的宽度切一版。",
    },
    DemoText {
        ago: 840,
        source: "Notes",
        bundle: "com.apple.Notes",
        favorite: false,
        text: "本周待办\n1. 整理 0.109 版本的更新说明\n2. 补一版空状态插画（浅色 / 深色）\n3. 和设计确认搜索的匹配规则：标题优先还是全文优先\n4. 周五前把演示视频的分镜脚本定下来",
    },
    DemoText {
        ago: 1300,
        source: "Google Chrome",
        bundle: "com.google.Chrome",
        favorite: true,
        text: "https://developer.apple.com/design/human-interface-guidelines/",
    },
    DemoText {
        ago: 1900,
        source: "Visual Studio Code",
        bundle: "com.microsoft.VSCode",
        favorite: false,
        text: "export function useDebouncedValue<T>(value: T, delay = 150): T {\n  const [debounced, setDebounced] = useState(value);\n  useEffect(() => {\n    const id = setTimeout(() => setDebounced(value), delay);\n    return () => clearTimeout(id);\n  }, [value, delay]);\n  return debounced;\n}",
    },
    DemoText {
        ago: 2600,
        source: "Figma",
        bundle: "com.figma.Desktop",
        favorite: true,
        text: "品牌主色  #2F6FED\n悬停态    #1F5BD8\n浅色底    #EDF3FF\n成功      #1FA971\n警告      #E8A317\n危险      #D64545\n正文      #1C1C1E\n次要文字  #6E6E73\n分隔线    #E5E5EA",
    },
    DemoText {
        ago: 3400,
        source: "Xcode",
        bundle: "com.apple.dt.Xcode",
        favorite: false,
        text: "func loadSnapshot() -> [ClipboardItem] {\n    let snapshot = clipboard_snapshot_acquire()\n    defer { clipboard_snapshot_release(snapshot) }\n    return decode(snapshot)\n}",
    },
    DemoText {
        ago: 4300,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: false,
        text: "Design is not just what it looks like and feels like. Design is how it works. The details are not the details — they make the product.",
    },
    DemoText {
        ago: 5200,
        source: "Terminal",
        bundle: "com.apple.Terminal",
        favorite: false,
        text: "curl -sS https://api.github.com/repos/wonaren/copy-attach/releases/latest \\\n  | jq -r '.tag_name, .published_at'",
    },
    DemoText {
        ago: 6400,
        source: "Obsidian",
        bundle: "md.obsidian",
        favorite: false,
        text: "| 快捷键 | 作用 |\n| --- | --- |\n| ⌥Space | 打开 / 关闭剪贴板 |\n| ⏎ | 粘贴选中条目 |\n| Space | 预览大图或全文 |\n| ⌥P | 收藏 / 取消收藏 |\n| ⌃⌫ | 删除 |\n| ⌘Z | 撤销删除 |",
    },
    DemoText {
        ago: 7600,
        source: "WeChat",
        bundle: "com.tencent.xinWeChat",
        favorite: false,
        text: "收货人：林小满  138 0013 8000\n上海市徐汇区漕溪北路 88 号 12 层",
    },
    DemoText {
        ago: 9100,
        source: "Visual Studio Code",
        bundle: "com.microsoft.VSCode",
        favorite: false,
        text: "{\n  \"editor.formatOnSave\": true,\n  \"editor.rulers\": [100],\n  \"rust-analyzer.check.command\": \"clippy\",\n  \"files.trimTrailingWhitespace\": true\n}",
    },
    DemoText {
        ago: 10800,
        source: "Slack",
        bundle: "com.tinyspeck.slackmacgap",
        favorite: false,
        text: "Shipping the demo build at 4pm — please don't touch the release branch until then.",
    },
    DemoText {
        ago: 12600,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: false,
        text: "^(?<protocol>https?):\\/\\/(?<host>[^\\/:]+)(?::(?<port>\\d+))?(?<path>\\/[^?#]*)?",
    },
    DemoText {
        ago: 14800,
        source: "Notes",
        bundle: "com.apple.Notes",
        favorite: false,
        text: "产品评审 · 10 月 18 日\n\n结论：\n- 历史列表默认展示 7 天，超出部分自动清理，收藏不受影响\n- 搜索支持拼音首字母，输入 jb 可以命中「剪贴板」\n- 大图预览的缩放上限提到 8 倍，双击复位\n\n待确认：\n- 多显示器下弹窗跟随鼠标还是跟随菜单栏（下次评审决定）",
    },
    DemoText {
        ago: 17200,
        source: "Google Chrome",
        bundle: "com.google.Chrome",
        favorite: false,
        text: "SELECT source_name, COUNT(*) AS n\nFROM clipboard_history\nWHERE timestamp > strftime('%s', 'now', '-7 days')\nGROUP BY source_name\nORDER BY n DESC\nLIMIT 5;",
    },
    DemoText {
        ago: 20000,
        source: "Terminal",
        bundle: "com.apple.Terminal",
        favorite: false,
        text: "services:\n  api:\n    build: .\n    ports: [\"8080:8080\"]\n    environment:\n      RUST_LOG: info\n    depends_on: [db]\n  db:\n    image: postgres:16\n    volumes: [\"pgdata:/var/lib/postgresql/data\"]",
    },
    DemoText {
        ago: 23000,
        source: "Visual Studio Code",
        bundle: "com.microsoft.VSCode",
        favorite: false,
        text: "def split_batches(items, size=500):\n    for start in range(0, len(items), size):\n        yield items[start:start + size]",
    },
    DemoText {
        ago: 26000,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: false,
        text: ".card {\n  border-radius: 12px;\n  box-shadow: 0 1px 2px rgb(0 0 0 / 6%), 0 8px 24px rgb(0 0 0 / 8%);\n  backdrop-filter: saturate(180%) blur(20px);\n}",
    },
    DemoText {
        ago: 30000,
        source: "WeChat",
        bundle: "com.tencent.xinWeChat",
        favorite: false,
        text: "【需求】剪贴板历史支持按应用筛选\n\n背景：用户经常在同一个应用里反复复制，希望只看到来自某个应用的记录。\n方案：\n1. 右上角增加应用筛选器，默认「全部应用」；\n2. 选项来自当前历史里出现过的应用，按使用频率排序；\n3. 与搜索、收藏同时生效，三者取交集；\n4. 筛选状态在本次会话内保留，重启后回到默认；\n5. 空结果显示「没有来自该应用的记录」，并提供一键清除筛选。\n\n边界：\n- 应用被卸载后仍保留名称（历史数据的来源信息以复制时为准）\n- 来源未知的条目归入「未知应用」\n- 筛选器不参与自动清理逻辑，只影响展示\n\n排期：设计 2 天，开发 3 天，联调 1 天。计划下个迭代的第一周上线。",
    },
    DemoText {
        ago: 34000,
        source: "Xcode",
        bundle: "com.apple.dt.Xcode",
        favorite: false,
        text: "error[E0502]: cannot borrow `history` as mutable because it is also borrowed as immutable\n  --> src/backend.rs:412:18\n   |\n412|         history.items.push(entry);\n   |         ------- ^^^^^ cannot borrow as mutable\n   |         |\n   |         immutable borrow occurs here",
    },
    DemoText {
        ago: 38000,
        source: "Mail",
        bundle: "com.apple.mail",
        favorite: false,
        text: "林小满 · 产品设计\nlinxiaoman@example.com\n+86 138 0013 8000",
    },
    DemoText {
        ago: 42000,
        source: "Notes",
        bundle: "com.apple.Notes",
        favorite: false,
        text: "好的工具应该消失在使用里，而不是要求用户记住它。",
    },
    DemoText {
        ago: 47000,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: false,
        text: "The clipboard is the oldest and least loved interface in the operating system. It has no visible surface, no settings worth opening, and no way to ask what it remembers. Everything you copy disappears into it, and everything you paste comes back out — usually the last thing, occasionally something you copied an hour ago and can no longer find.\n\nA history changes that relationship. Once the clipboard keeps a list, copying stops being destructive: the previous item is still there, the link you meant to save is still there, and the screenshot you took four minutes ago is still there. The cost is a new kind of clutter, and the design problem becomes one of retrieval rather than storage.\n\nRetrieval is where most clipboard managers fall apart. A long list is not a memory; it is an archive. The useful ones keep the list short enough to scan, make search fast enough to trust, and put the paste action exactly where the pointer already is. Everything else — tagging, folders, sync — is an attempt to make the archive feel organised instead of making the list unnecessary.\n\nThe best version of this feature is the one you stop noticing. You press the shortcut, you type three letters, you press return, and the thing you wanted is in the document. No window management, no menu hunting, no decision about where it should live. If the tool is doing its job, the only evidence it exists is that you stopped losing things.",
    },
];

const IMAGES: &[DemoImage] = &[
    DemoImage {
        ago: 700,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: false,
        file: "01-analytics.jpg",
        url: "https://images.unsplash.com/photo-1551288049-bebda4e38f71?w=1920&q=80",
    },
    DemoImage {
        ago: 2100,
        source: "Visual Studio Code",
        bundle: "com.microsoft.VSCode",
        favorite: false,
        file: "02-code.jpg",
        url: "https://images.unsplash.com/photo-1461749280684-dccba630e2f6?w=1920&q=80",
    },
    DemoImage {
        ago: 3900,
        source: "Figma",
        bundle: "com.figma.Desktop",
        favorite: true,
        file: "03-wireframes.jpg",
        url: "https://images.unsplash.com/photo-1522542550221-31fd19575a2d?w=1920&q=80",
    },
    DemoImage {
        ago: 6800,
        source: "Google Chrome",
        bundle: "com.google.Chrome",
        favorite: false,
        file: "04-commerce.jpg",
        url: "https://images.unsplash.com/photo-1460925895917-afdab827c52f?w=1920&q=80",
    },
    DemoImage {
        ago: 11500,
        source: "Messages",
        bundle: "com.apple.MobileSMS",
        favorite: false,
        file: "05-cat.jpg",
        url: "https://images.unsplash.com/photo-1518791841217-8f162f1e1131?w=1920&q=80",
    },
    DemoImage {
        ago: 15800,
        source: "Photos",
        bundle: "com.apple.Photos",
        favorite: false,
        file: "06-lake.jpg",
        url: "https://images.unsplash.com/photo-1501785888041-af3ef285b470?w=1920&q=80",
    },
    DemoImage {
        ago: 21500,
        source: "WeChat",
        bundle: "com.tencent.xinWeChat",
        favorite: false,
        file: "07-coffee.jpg",
        url: "https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?w=1920&q=80",
    },
    DemoImage {
        ago: 35000,
        source: "Safari",
        bundle: "com.apple.Safari",
        favorite: false,
        file: "08-portrait.jpg",
        url: "https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=1920&q=80",
    },
];

pub struct Summary {
    pub texts: usize,
    pub images: usize,
    pub bytes: u64,
    pub generated_at: u64,
}

pub fn generate(path: &Path, images_dir: &Path) -> Result<Summary, String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    if path.exists() {
        return Err(format!("{} already exists", path.display()));
    }
    let tmp = tmp_path(path);
    remove_db_files(&tmp);

    let generated_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock is before the epoch: {e}"))?
        .as_secs();

    let conn = Connection::open(&tmp).map_err(|e| format!("cannot open {}: {e}", tmp.display()))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = OFF;",
    )
    .map_err(|e| format!("cannot configure {}: {e}", tmp.display()))?;
    ensure_history_table(&conn).map_err(|e| format!("cannot create schema: {e}"))?;

    let mut items: Vec<(u64, Item)> = Vec::with_capacity(TEXTS.len() + IMAGES.len());
    for (i, t) in TEXTS.iter().enumerate() {
        items.push((t.ago, Item::Text(i)));
    }
    for (i, img) in IMAGES.iter().enumerate() {
        items.push((img.ago, Item::Image(i)));
    }
    items.sort_by_key(|(ago, _)| std::cmp::Reverse(*ago));

    let mut favorites: Vec<u64> = Vec::new();
    let mut images = 0usize;
    for (id, (ago, item)) in (1u64..).zip(items.iter()) {
        let timestamp = generated_at.saturating_sub(*ago);
        match item {
            Item::Text(i) => {
                let t = &TEXTS[*i];
                let entry = ClipboardEntry::text_entry(
                    id,
                    t.text,
                    timestamp,
                    t.source.to_string(),
                    t.bundle.to_string(),
                    0,
                );
                insert_entry_to_db(&conn, &entry, Some(t.text), None, None)
                    .map_err(|_| format!("failed to insert text entry {id}"))?;
                if t.favorite {
                    favorites.push(id);
                }
            }
            Item::Image(i) => {
                let d = &IMAGES[*i];
                let file = cached_image(images_dir, d)?;
                let (rgba, width, height) = load_rgba(&file)?;
                let png = encode_png(width, height, &rgba)
                    .ok_or_else(|| format!("PNG encode failed for {}", file.display()))?;
                let (thumb_png, tw, th) = create_thumbnail_fast(width, height, &rgba)
                    .ok_or_else(|| format!("thumbnail failed for {}", file.display()))?;
                let entry = ClipboardEntry::Image {
                    id,
                    width,
                    height,
                    thumb_width: tw,
                    thumb_height: th,
                    hash: image_hash(&rgba, width, height),
                    custom_label: String::new(),
                    timestamp,
                    source_name: d.source.to_string(),
                    source_bundle_id: d.bundle.to_string(),
                    db_id: 0,
                };
                insert_entry_to_db(&conn, &entry, None, Some(&png), Some((&thumb_png, tw, th)))
                    .map_err(|_| format!("failed to insert image entry {id}"))?;
                if d.favorite {
                    favorites.push(id);
                }
                images += 1;
            }
        }
    }

    for id in &favorites {
        set_favorite(&conn, *id, true).map_err(|_| format!("failed to favorite entry {id}"))?;
    }

    conn.execute(
        "INSERT INTO clipboard_meta (key, value) VALUES (?1, ?2)",
        rusqlite::params![MARKER_KEY, generated_at as i64],
    )
    .map_err(|e| format!("cannot write demo marker: {e}"))?;

    conn.pragma_update(None, "user_version", METADATA_VERSION)
        .map_err(|e| format!("cannot stamp user_version: {e}"))?;

    conn.query_row("PRAGMA journal_mode = DELETE", [], |row| row.get::<_, String>(0))
        .map_err(|e| format!("cannot checkpoint journal: {e}"))?;
    drop(conn);

    fs::rename(&tmp, path).map_err(|e| {
        format!("cannot move {} to {}: {e}", tmp.display(), path.display())
    })?;

    Ok(Summary {
        texts: TEXTS.len(),
        images,
        bytes: fs::metadata(path).map(|m| m.len()).unwrap_or(0),
        generated_at,
    })
}

fn cached_image(dir: &Path, image: &DemoImage) -> Result<PathBuf, String> {
    fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let path = dir.join(image.file);
    if path.exists() {
        return Ok(path);
    }
    let part = path.with_extension("part");
    let _ = fs::remove_file(&part);
    println!("downloading {} ({})", image.file, image.url);
    let output = Command::new("/usr/bin/curl")
        .args(["-fsSL", "--retry", "3", "--retry-delay", "2", "--max-time", "90", "-o"])
        .arg(&part)
        .arg(image.url)
        .output()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    if !output.status.success() {
        let _ = fs::remove_file(&part);
        return Err(format!(
            "download failed for {} ({}): {}",
            image.file,
            image.url,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    fs::rename(&part, &path)
        .map_err(|e| format!("cannot move {} into place: {e}", part.display()))?;
    Ok(path)
}

fn load_rgba(path: &Path) -> Result<(Vec<u8>, u32, u32), String> {
    let bytes = fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let decoded = image::load_from_memory(&bytes)
        .map_err(|e| format!("{} is not a decodable image: {e}", path.display()))?;
    let rgba = decoded.to_rgba8();
    let (width, height) = rgba.dimensions();
    Ok((rgba.into_raw(), width, height))
}

fn tmp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
}

pub fn remove_db_files(path: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        let _ = fs::remove_file(PathBuf::from(name));
    }
}

#[derive(Clone, Copy)]
enum Item {
    Text(usize),
    Image(usize),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_db_loads_through_the_reader() {
        let dir = std::env::temp_dir().join(format!("copyattach_demo_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let images = dir.join("images");
        fs::create_dir_all(&images).unwrap();
        let pixels = vec![128u8; 24 * 16 * 4];
        let png = encode_png(24, 16, &pixels).unwrap();
        for image in IMAGES {
            fs::write(images.join(image.file), &png).unwrap();
        }
        let path = dir.join("history.db");

        let summary = generate(&path, &images).expect("generate demo db");
        assert_eq!(summary.texts, TEXTS.len());
        assert_eq!(summary.images, IMAGES.len());

        let conn = Connection::open(&path).unwrap();
        let loaded = crate::db::load_history_from_db(&conn, 10_000);
        assert_eq!(loaded.len(), TEXTS.len() + IMAGES.len());
        assert!(loaded.iter().all(|e| match e {
            ClipboardEntry::Text { preview, .. } => !preview.is_empty(),
            ClipboardEntry::Image { thumb_width, .. } => *thumb_width > 0,
        }));
        let favorites = crate::db::load_favorites(&conn).unwrap();
        assert_eq!(favorites.len(), 4);

        let (png, width, height): (Vec<u8>, i64, i64) = conn
            .query_row(
                "SELECT png_data, width, height FROM clipboard_history WHERE entry_type = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        let (_, decoded_w, decoded_h) =
            crate::image::decode_png(&png).expect("full PNG must decode");
        assert_eq!((i64::from(decoded_w), i64::from(decoded_h)), (width, height));

        let (thumb, thumb_w, thumb_h): (Vec<u8>, i64, i64) = conn
            .query_row(
                "SELECT thumb_data, thumb_width, thumb_height
                 FROM clipboard_history WHERE entry_type = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        let (_, thumb_dw, thumb_dh) =
            crate::image::decode_png(&thumb).expect("thumbnail PNG must decode");
        assert_eq!((i64::from(thumb_dw), i64::from(thumb_dh)), (thumb_w, thumb_h));
    }
}
