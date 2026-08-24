#!/bin/bash
# CopyAttach 压力测试编排脚本
#
# 用法：
#   完整测试：   bash stress_test.sh
#   快速测试：   bash stress_test.sh --quick        (1000 条)
#   仅生成数据： bash stress_test.sh --generate-only (10000 条)
#   仅采集指标： bash stress_test.sh --measure-only  (使用现有 DB)
#   自定义：     bash stress_test.sh --count 1000 --text-ratio 0.5
#
# 前提条件：
#   - Rust 工具链
#   - macOS 开发工具（heap, vmmap, top, ps）
#   - sudo（powermetrics 需要，可选）

set -e

# ─── 配置 ─────────────────────────────────────────────────────────────────────
COUNT=${COUNT:-10000}
TEXT_RATIO=${TEXT_RATIO:-0.6}
SEED=${SEED:-42}
THRESHOLD=10000

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_PATH="${HOME}/Library/Application Support/CopyAttach/history.db"
BACKUP_DB="${DB_PATH}.stress_backup"
STRESS_DB="/tmp/copyattach_stress.db"
REPORT="/tmp/copyattach_stress_report.md"

# ─── 函数 ────────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$REPORT"; }
h1()   { echo; echo "══════════════════════════════════════════════════════════════"; echo "  $*"; echo; }

cleanup() {
    log "清理..."
    if [ -f "$BACKUP_DB" ]; then
        log "恢复原始 DB"
        mv "$BACKUP_DB" "$DB_PATH"
    fi
    killall CopyAttach 2>/dev/null || true
}

# ─── 确保退出时恢复 ──────────────────────────────────────────────────────────
trap cleanup EXIT INT TERM

# ─── 创建报告 ────────────────────────────────────────────────────────────────

cat > "$REPORT" <<'HEADER'
# CopyAttach Stress Test Report
HEADER
echo "Generated: $(date)" >> "$REPORT"
echo "Platform: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))" >> "$REPORT"
echo "" >> "$REPORT"

# ─── 1. 构建 stress-gen ──────────────────────────────────────────────────────

h1 "Phase 1: Build stress-gen CLI"
cd "$PROJECT_DIR"
log "Building stress-gen (cargo build --features stress-test)..."
cargo build --release --features stress-test 2>&1 | tail -5
log "Build complete"

if [ "$1" = "--measure-only" ]; then
    log "跳过数据生成（--measure-only）"
else
    # ─── 2. 生成测试数据 ──────────────────────────────────────────────────
    h1 "Phase 2: Generate test data"

    log "移除旧压力测试数据库"
    rm -f "$STRESS_DB"

    log "运行 stress-gen (${COUNT} 条, 文本 ${TEXT_RATIO})..."
    cargo run --release --bin stress-gen --features stress-test -- \
        --count "$COUNT" --text-ratio "$TEXT_RATIO" --seed "$SEED" \
        --db-path "$STRESS_DB" --threshold "$THRESHOLD" --report 2>&1 | tee -a "$REPORT"

    log "数据生成完成"
fi

# Measure only: use existing DB
if [ "$1" = "--generate-only" ]; then
    log "跳过指标采集（--generate-only）"
    echo "Test data generated at: ${STRESS_DB}" >> "$REPORT"
    echo "Run with --measure-only to collect metrics." >> "$REPORT"
    trap '' EXIT  # Don't restore, user wants the data
    exit 0
fi

if [ "$1" = "--measure-only" ]; then
    STRESS_DB="$DB_PATH"
    log "使用现有 DB: $DB_PATH"
fi

# ─── 3. 备份并替换 DB ───────────────────────────────────────────────────────

h1 "Phase 3: Deploy test database"
log "备份原始 DB → ${BACKUP_DB}"
cp "$DB_PATH" "$BACKUP_DB" 2>/dev/null || log "(无原始 DB，跳过备份)"

log "部署测试 DB"
cp "$STRESS_DB" "$DB_PATH"
DB_SIZE=$(stat -f%z "$DB_PATH" 2>/dev/null || stat -c%s "$DB_PATH" 2>/dev/null)
log "DB 大小: $(echo "scale=2; $DB_SIZE/1048576" | bc) MB"
echo "DB Size: $(echo "scale=2; $DB_SIZE/1048576" | bc) MB" >> "$REPORT"

# ─── 4. 启动 App ─────────────────────────────────────────────────────────────

h1 "Phase 4: Launch app and collect baseline metrics"

log "启动 CopyAttach..."
open "${PROJECT_DIR}/CopyAttach.app"
sleep 4  # Wait for initial load

# Get PID
PID=$(pgrep CopyAttach | head -1)
if [ -z "$PID" ]; then
    log "错误：CopyAttach 未运行"
    exit 1
fi
log "PID: ${PID}"

# ─── 5. 内存基准 ────────────────────────────────────────────────────────────

h1 "Phase 5: Memory measurement"

log "=== heap ===" >> "$REPORT"
heap CopyAttach 2>&1 | head -30 >> "$REPORT"
echo "" >> "$REPORT"

log "=== vmmap (summary) ===" >> "$REPORT"
vmmap --summary CopyAttach 2>&1 | head -30 >> "$REPORT"
echo "" >> "$REPORT"

log "=== ps (RSS/CPU) ===" >> "$REPORT"
ps -o pid,rss,cpu -p "$PID" >> "$REPORT" 2>&1
echo "" >> "$REPORT"

# Parse RSS from ps (in KB)
RSS=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
RSS_MB=$(echo "scale=1; $RSS / 1024" | bc)
log "RSS: ${RSS_MB} MB"

echo "Baseline RSS: ${RSS_MB} MB" >> "$REPORT"

# ─── 6. CPU 采样 ─────────────────────────────────────────────────────────────

h1 "Phase 6: CPU sampling"
log "采样 5 秒 CPU/内存..."
top -l 5 -pid "$PID" -stats pid,cpu,mem -n 1 2>&1 | tail -10 >> "$REPORT"

# ─── 7. 功耗测量（可选，需 sudo） ─────────────────────────────────────────

h1 "Phase 7: Power measurement (optional)"

if command -v powermetrics &>/dev/null; then
    log "尝试 powermetrics（可能需要 sudo）..."
    if sudo -n true 2>/dev/null; then
        sudo powermetrics --samplers tasks -i 1000 -n 3 --show-process-energy --hide-cpu-duty-cycle 2>&1 | \
            grep -A 5 "CopyAttach" >> "$REPORT" || log "powermetrics: 无 CopyAttach 数据"
        log "powermetrics 完成"
    else
        log "powermetrics 需要 sudo，已跳过（可手动运行：sudo powermetrics --samplers tasks -i 1000）"
        echo "Power measurement skipped (requires sudo)" >> "$REPORT"
    fi
else
    log "powermetrics 不可用，已跳过"
    echo "Power measurement skipped (powermetrics not available)" >> "$REPORT"
fi

# ─── 8. 冷启动时间测量 ─────────────────────────────────────────────────────

h1 "Phase 8: Cold-start timing measurement"
log "重启 app 测量冷启动..."
killall CopyAttach 2>/dev/null || true
sleep 1

START_TS=$(date +%s%N)
open "${PROJECT_DIR}/CopyAttach.app"

# Wait until the process appears and stabilizes
for i in $(seq 1 20); do
    sleep 0.5
    PID_NEW=$(pgrep CopyAttach | head -1)
    if [ -n "$PID_NEW" ]; then
        END_TS=$(date +%s%N)
        STARTUP_MS=$(echo "scale=1; ($END_TS - $START_TS) / 1000000" | bc)
        log "冷启动时间: ~${STARTUP_MS} ms（进程出现）"
        echo "Cold start (process): ${STARTUP_MS} ms" >> "$REPORT"
        PID="$PID_NEW"
        break
    fi
done

# Wait for initial snapshot load
sleep 3

# Measure RSS after cold start
RSS_COLD=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
if [ -n "$RSS_COLD" ]; then
    RSS_COLD_MB=$(echo "scale=1; $RSS_COLD / 1024" | bc)
    log "冷启动后 RSS: ${RSS_COLD_MB} MB"
    echo "Cold start RSS: ${RSS_COLD_MB} MB" >> "$REPORT"
fi

# ─── 9. 汇总 ─────────────────────────────────────────────────────────────

h1 "Phase 9: Summary"
cat "$REPORT"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  完成！报告保存至: ${REPORT}"
echo "  原始 DB 已恢复"
echo "══════════════════════════════════════════════════════════════"
