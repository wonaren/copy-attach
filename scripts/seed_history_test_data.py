import argparse
from contextlib import closing
from datetime import datetime
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import time
from uuid import uuid4
import zlib


DEFAULT_DB = Path.home() / "Library/Application Support/CopyAttach/history.db"
TOTAL = 500
SOURCE_NAME = "阈值测试"
SOURCE_BUNDLE = "cc.wonaren.copyattach.threshold-test"


def require_app_closed():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "CopyAttach"], capture_output=True)
    if result.returncode == 0:
        raise RuntimeError("请先退出 CopyAttach，再运行脚本。")
    if result.returncode != 1:
        raise RuntimeError("无法确认 CopyAttach 已退出，请在 macOS 终端中运行。")


def content_hash(data):
    value = 0xCBF29CE484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001B3) & ((1 << 64) - 1)
    return value if value < (1 << 63) else value - (1 << 64)


def png_chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def make_image(index, batch):
    width, height = ((96, 64), (144, 96), (192, 128))[index % 3]
    red, green, blue = batch.bytes[:3]
    first = bytes(((red + index) % 256, green, blue, 255))
    second = bytes((blue, (green + index // 256) % 256, red, 255))
    rows = (first * (width // 2) + second * (width // 2),
            second * (width // 2) + first * (width // 2))
    scanlines = (b"\0" + rows[0]) * (height // 2) + (b"\0" + rows[1]) * (height // 2)
    rgba = (rows[0] * (height // 2)) + (rows[1] * (height // 2))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
           + png_chunk(b"IDAT", zlib.compress(scanlines)) + png_chunk(b"IEND", b""))
    return png, width, height, content_hash(struct.pack("<II", width, height) + rgba)


def write_rows(conn, watermark, oldest, batch):
    last_timestamp = min(oldest, int(time.time())) - 1
    for index in range(TOTAL):
        entry_id = watermark + index + 1
        timestamp = max(0, last_timestamp - (TOTAL - index - 1))
        common = (entry_id, timestamp, SOURCE_NAME, SOURCE_BUNDLE)
        if index % 5 < 3:
            label = f"{SOURCE_NAME} · 文本 {index + 1:03d} · {batch.hex[:8]}"
            conn.execute(
                """INSERT INTO clipboard_history
                   (entry_id, timestamp, source_name, source_bundle_id,
                    entry_type, text, preview, label, hash)
                   VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)""",
                (*common, label, label, label, content_hash(label.encode("utf-8"))),
            )
        else:
            png, width, height, image_hash = make_image(index, batch)
            conn.execute(
                """INSERT INTO clipboard_history
                   (entry_id, timestamp, source_name, source_bundle_id,
                    entry_type, png_data, width, height, thumb_data,
                    thumb_width, thumb_height, hash, custom_label)
                   VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (*common, png, width, height, png, width, height, image_hash,
                 f"{SOURCE_NAME} · 图片 {index + 1:03d} · {batch.hex[:8]}"),
            )
    conn.execute(
        """INSERT INTO clipboard_meta (key, value) VALUES ('entry_id_watermark', ?)
           ON CONFLICT(key) DO UPDATE SET value = excluded.value""",
        (watermark + TOTAL,),
    )


def backup_db(db, count):
    directory = db.parent / "backups"
    directory.mkdir(mode=0o700, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    with tempfile.NamedTemporaryFile(
        dir=directory, prefix=f"history_before_threshold_test_{stamp}_", suffix=".db", delete=False
    ) as file:
        backup = Path(file.name)
    try:
        with (closing(sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True)) as source,
              closing(sqlite3.connect(backup)) as target):
            source.backup(target)
            if target.execute("SELECT COUNT(*) FROM clipboard_history").fetchone()[0] != count:
                raise RuntimeError("备份行数与原库不一致，停止写入。")
    except (OSError, RuntimeError, sqlite3.Error):
        backup.unlink(missing_ok=True)
        raise
    return backup


def main():
    parser = argparse.ArgumentParser(description="向 CopyAttach 历史库追加 300 条测试文本和 200 张测试图片。")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="指定已有数据库，默认使用真实历史库。")
    db = parser.parse_args().db.expanduser().resolve()
    try:
        using_default_db = db == DEFAULT_DB.resolve()
        if using_default_db:
            require_app_closed()
        with closing(sqlite3.connect(f"{db.as_uri()}?mode=rw", uri=True)) as conn, conn:
            conn.execute("BEGIN IMMEDIATE")
            count, highest = conn.execute(
                "SELECT COUNT(*), MAX(entry_id) FROM clipboard_history"
            ).fetchone()
            oldest = conn.execute(
                """SELECT MIN(timestamp) FROM clipboard_history
                   WHERE source_bundle_id != ?
                     AND id NOT IN (SELECT row_id FROM clipboard_deleted)
                     AND entry_id NOT IN (SELECT entry_id FROM clipboard_favorites)
                     AND entry_id NOT IN (SELECT entry_id FROM clipboard_quick_slots)""",
                (SOURCE_BUNDLE,),
            ).fetchone()[0]
            if oldest is not None and oldest <= 0:
                raise RuntimeError("原库有时间戳为 0 或更早的普通记录，无法确保测试记录先被清理。")
            row = conn.execute(
                "SELECT value FROM clipboard_meta WHERE key = 'entry_id_watermark'"
            ).fetchone()
            watermark = max(highest or 0, row[0] if row else 0)
            backup = backup_db(db, count)
            print(f"已备份并核对 {count} 条记录，文件位于 {backup}", flush=True)
            batch = uuid4()
            write_rows(conn, watermark, oldest if oldest is not None else int(time.time()), batch)
            new_count = conn.execute("SELECT COUNT(*) FROM clipboard_history").fetchone()[0]
            if new_count != count + TOTAL:
                raise RuntimeError("追加后的记录数不符，已回滚。")
            if using_default_db:
                require_app_closed()
    except (OSError, RuntimeError, sqlite3.Error) as error:
        parser.exit(1, f"写入失败：{error}\n")

    print(f"已追加 500 条（文本 300 条，图片 200 张）。批次 {batch.hex[:8]}，库内总行数 {new_count}。")
    print(f"重新打开 CopyAttach 后，可搜索「{SOURCE_NAME}」。启动时会按当前阈值清理。")


if __name__ == "__main__":
    main()
