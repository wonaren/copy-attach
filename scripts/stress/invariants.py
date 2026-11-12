#!/usr/bin/env python3
import argparse
import sqlite3
import sys
from pathlib import Path

LIVE = "NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id = h.id)"
ORDINARY = (
    "NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id = h.id) "
    "AND h.entry_id NOT IN (SELECT entry_id FROM clipboard_favorites) "
    "AND h.entry_id NOT IN (SELECT entry_id FROM clipboard_quick_slots)"
)

CHECKS = []


def check(name, sql, params=(), expect_empty=True):
    try:
        rows = conn.execute(sql, params).fetchall()
    except sqlite3.Error as exc:
        CHECKS.append((name, False, f"SQL error: {exc}"))
        return []
    ok = (len(rows) == 0) if expect_empty else True
    detail = "" if ok else f"{len(rows)} row(s), first={rows[0]}"
    CHECKS.append((name, ok, detail))
    return rows


def scalar(sql, params=()):
    try:
        row = conn.execute(sql, params).fetchone()
        return row[0] if row else None
    except sqlite3.Error as exc:
        CHECKS.append(("scalar", False, f"SQL error: {exc}"))
        return None


def assert_value(name, value, ok, detail=""):
    CHECKS.append((name, bool(ok), detail if not ok else ""))


def table_exists(name):
    return scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ) == 1


def main():
    global conn
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--threshold", type=int)
    ap.add_argument(
        "--mode",
        choices=["rest", "after-capture", "generated", "backup", "restore"],
        default="rest",
    )
    ap.add_argument("--db-ids", help="file with one db_id per line collected from a snapshot")
    ap.add_argument("--report", help="append a markdown section to this file")
    args = ap.parse_args()

    db = Path(args.db)
    if not db.exists():
        print(f"FAIL: database not found: {db}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row

    if not table_exists("clipboard_history"):
        print("FAIL: clipboard_history missing", file=sys.stderr)
        return 2

    if args.db_ids:
        ids = [int(x) for x in Path(args.db_ids).read_text().split() if x.strip()]
        conn.execute("CREATE TEMP TABLE observed_db_ids(db_id INTEGER PRIMARY KEY)")
        conn.executemany("INSERT OR IGNORE INTO observed_db_ids VALUES (?)", [(i,) for i in ids])
        check(
            "db_id 指向活行",
            "SELECT o.db_id FROM observed_db_ids o "
            "LEFT JOIN clipboard_history h ON h.id = o.db_id "
            "LEFT JOIN clipboard_deleted d ON d.row_id = o.db_id "
            "WHERE h.id IS NULL OR d.row_id IS NOT NULL",
        )

    if args.mode != "backup":
        check(
            "收藏无孤儿",
            "SELECT f.entry_id FROM clipboard_favorites f WHERE NOT EXISTS ("
            "SELECT 1 FROM clipboard_history h WHERE h.entry_id = f.entry_id AND " + LIVE + ")",
        )
        check(
            "收藏未指向已软删条目",
            "SELECT f.entry_id FROM clipboard_favorites f "
            "JOIN clipboard_history h ON h.entry_id = f.entry_id "
            "JOIN clipboard_deleted d ON d.row_id = h.id",
        )
        check(
            "快捷槽位无孤儿",
            "SELECT q.slot, q.entry_id FROM clipboard_quick_slots q WHERE NOT EXISTS ("
            "SELECT 1 FROM clipboard_history h WHERE h.entry_id = q.entry_id AND " + LIVE + ")",
        )
        check("快捷槽位范围 1-9", "SELECT slot FROM clipboard_quick_slots WHERE slot NOT BETWEEN 1 AND 9")
        check(
            "快捷槽位 entry_id 唯一",
            "SELECT entry_id FROM clipboard_quick_slots GROUP BY entry_id HAVING COUNT(*) > 1",
        )
        check(
            "撤销侧表无孤儿",
            "SELECT d.row_id FROM clipboard_deleted d "
            "LEFT JOIN clipboard_history h ON h.id = d.row_id WHERE h.id IS NULL",
        )
        check(
            "撤销侧表 entry_id 与载荷一致",
            "SELECT d.row_id FROM clipboard_deleted d "
            "JOIN clipboard_history h ON h.id = d.row_id WHERE d.entry_id <> h.entry_id",
        )
        check(
            "撤销侧表标记合法",
            "SELECT row_id FROM clipboard_deleted WHERE was_favorite NOT IN (0,1) "
            "OR was_slot NOT BETWEEN 0 AND 9",
        )
        check(
            "活行文本内容不重复",
            "SELECT h.hash, COUNT(*) FROM clipboard_history h "
            "WHERE h.entry_type = 0 AND " + LIVE + " GROUP BY h.hash, h.text HAVING COUNT(*) > 1",
        )
        check(
            "活行图片内容不重复",
            "SELECT h.hash, COUNT(*) FROM clipboard_history h "
            "WHERE h.entry_type = 1 AND " + LIVE + " GROUP BY h.hash HAVING COUNT(*) > 1",
        )
        check(
            "活行 entry_id 唯一",
            "SELECT h.entry_id, COUNT(*) FROM clipboard_history h "
            "WHERE " + LIVE + " GROUP BY h.entry_id HAVING COUNT(*) > 1",
        )
        check(
            "活行可加载",
            "SELECT h.id FROM clipboard_history h WHERE " + LIVE + " AND ("
            "h.entry_type NOT IN (0,1) "
            "OR (h.entry_type = 0 AND (h.text IS NULL OR h.hash IS NULL OR h.preview = '')) "
            "OR (h.entry_type = 1 AND (h.png_data IS NULL OR h.thumb_data IS NULL)))",
        )

        watermark = scalar("SELECT value FROM clipboard_meta WHERE key='entry_id_watermark'")
        max_entry = scalar("SELECT COALESCE(MAX(entry_id),0) FROM clipboard_history") or 0
        assert_value(
            "entry_id_watermark 覆盖最大 entry_id",
            watermark,
            (watermark is not None and int(watermark) >= int(max_entry)) or int(max_entry) == 0,
            f"watermark={watermark} max_entry_id={max_entry}",
        )
        seq = scalar("SELECT seq FROM sqlite_sequence WHERE name='clipboard_history'")
        max_id = scalar("SELECT COALESCE(MAX(id),0) FROM clipboard_history") or 0
        assert_value(
            "AUTOINCREMENT 高水位不低于最大 id",
            seq,
            seq is None or int(seq) >= int(max_id),
            f"seq={seq} max_id={max_id}",
        )

        if args.threshold is not None:
            live = scalar(
                "SELECT COUNT(*) FROM clipboard_history h WHERE " + LIVE
            ) or 0
            protected = scalar(
                "SELECT COUNT(*) FROM clipboard_history h "
                "WHERE NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id = h.id) "
                "AND (h.entry_id IN (SELECT entry_id FROM clipboard_favorites) "
                "OR h.entry_id IN (SELECT entry_id FROM clipboard_quick_slots))"
            ) or 0
            ordinary = scalar(
                "SELECT COUNT(*) FROM clipboard_history h WHERE " + ORDINARY
            ) or 0
            allowed = max(0, args.threshold - protected)
            if args.mode in ("after-capture", "generated"):
                allowed += 1
            assert_value(
                "清理阈值与受保护条目",
                ordinary,
                ordinary <= allowed,
                f"ordinary={ordinary} allowed={allowed} (live={live} protected={protected} threshold={args.threshold})",
            )

        budget = scalar("SELECT value FROM clipboard_meta WHERE key='undo_budget_bytes'")
        budget = -1 if budget is None else int(budget)
        depth = scalar(
            "SELECT COUNT(*) FROM clipboard_deleted d JOIN clipboard_history h ON h.id = d.row_id"
        ) or 0
        if budget < 0:
            assert_value(
                "撤销深度不超过条数上限",
                depth,
                depth <= -budget,
                f"depth={depth} cap={-budget}",
            )
        elif budget > 0:
            retained = scalar(
                "SELECT COALESCE(SUM(COALESCE(LENGTH(CAST(h.text AS BLOB)),0) "
                "+ COALESCE(LENGTH(h.png_data),0) + COALESCE(LENGTH(h.thumb_data),0)),0) "
                "FROM clipboard_deleted d JOIN clipboard_history h ON h.id = d.row_id"
            ) or 0
            assert_value(
                "撤销保留字节不超过预算",
                retained,
                retained <= budget,
                f"retained={retained} budget={budget}",
            )
        if args.mode == "rest":
            expired = scalar(
                "SELECT COUNT(*) FROM clipboard_deleted "
                "WHERE deleted_at < (CAST(strftime('%s','now') AS INTEGER) * 1000000 - 604800000000)"
            ) or 0
            assert_value("过期撤销记录已清理", expired, expired == 0, f"expired={expired}")

    if args.mode == "backup":
        check(
            "备份 total_items 与实际行数一致",
            "SELECT value FROM clipboard_backup_meta WHERE key='total_items' AND "
            "CAST(value AS INTEGER) <> (SELECT COUNT(*) FROM clipboard_history)",
        )
        if table_exists("clipboard_deleted"):
            check("备份不含撤销侧表行", "SELECT row_id FROM clipboard_deleted LIMIT 1")
        check(
            "备份槽位无孤儿",
            "SELECT entry_id FROM clipboard_quick_slots "
            "WHERE entry_id NOT IN (SELECT entry_id FROM clipboard_history)",
        )
        if table_exists("clipboard_backup_favorites"):
            check(
                "备份收藏无孤儿",
                "SELECT f.entry_id FROM clipboard_backup_favorites f "
                "WHERE f.entry_id NOT IN (SELECT entry_id FROM clipboard_history)",
            )
        freelist = scalar("PRAGMA freelist_count")
        if freelist:
            CHECKS.append(("备份空闲页为 0", False, f"freelist_count={freelist}"))

    if args.mode == "restore" and table_exists("clipboard_deleted"):
        check("恢复后撤销侧表为空", "SELECT row_id FROM clipboard_deleted LIMIT 1")

    failures = [c for c in CHECKS if not c[1]]
    lines = ["", f"### Invariants ({args.mode})", "", f"`{db}`", ""]
    for name, ok, detail in CHECKS:
        lines.append(f"- {'PASS' if ok else 'FAIL'} {name}" + (f" — {detail}" if detail else ""))
    text = "\n".join(lines) + "\n"
    print(text)
    if args.report:
        with open(args.report, "a") as fh:
            fh.write(text)
    if failures:
        print(f"FAIL: {len(failures)} invariant check(s) failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
