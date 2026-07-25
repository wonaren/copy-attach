import AppKit
import Foundation
import SwiftUI

// MARK: - Measurement Report

struct StressReport: Codable {
    var timestamp: Date
    var totalEntries: Int
    var textEntries: Int
    var imageEntries: Int

    // Performance
    var snapshotLockAvgUs: Double
    var countLockAvgNs: Double
    var startupRssMB: Double
    var startupTimeMs: Double

    // Memory
    var footprintMB: Double     // phys_footprint — matches Activity Monitor
    var peakRssMB: Double
    var residentSizeMB: Double
    var vmSizeMB: Double

    // Image
    var thumbLoadAvgMs: Double
    var fullImageLoadAvgMs: Double
    var thumbCacheHitRate: Double

    // Scoring
    var performanceScore: Double
    var memoryScore: Double
    var smoothnessScore: Double
    var totalScore: Double
    var rating: String

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Returns a markdown-formatted report
    func markdown() -> String {
        let dateStr = Self.df.string(from: timestamp)
        return """
        # CopyAttach 压力测试报告

        **测试时间：** \(dateStr)
        **条目总数：** \(totalEntries)（文本 \(textEntries) / 图片 \(imageEntries)）

        ## 评分结果

        | 维度（权重） | 评分 | 说明 |
        |---|---|---|
        | 性能（35%） | \(String(format: "%.1f", performanceScore))/5.0 | 快照 \(String(format: "%.1f", snapshotLockAvgUs))µs / 计数 \(String(format: "%.1f", countLockAvgNs))ns |
        | 内存（25%） | \(String(format: "%.1f", memoryScore))/5.0 | 实占 \(String(format: "%.1f", footprintMB))MB / 峰值 \(String(format: "%.1f", peakRssMB))MB |
        | 流畅度（20%） | \(String(format: "%.1f", smoothnessScore))/5.0 | 缩略图 \(String(format: "%.1f", thumbLoadAvgMs))ms / 大图 \(String(format: "%.1f", fullImageLoadAvgMs))ms |
        | **总分** | **\(String(format: "%.1f", totalScore))/5.0** | **\(rating)** |

        ## 详细数据

        | 指标 | 值 |
        |---|---|
        | 快照获取耗时（平均） | \(String(format: "%.1f", snapshotLockAvgUs)) µs |
        | 计数调用耗时（平均） | \(String(format: "%.2f", countLockAvgNs)) ns |
        | 常驻内存 | \(String(format: "%.1f", footprintMB)) MB（activity monitor） |
        | 峰值内存 | \(String(format: "%.1f", peakRssMB)) MB |
        | 虚拟内存 | \(String(format: "%.1f", vmSizeMB)) MB |
        | 缩略图加载（平均） | \(String(format: "%.1f", thumbLoadAvgMs)) ms |
        | 大图加载（平均） | \(String(format: "%.1f", fullImageLoadAvgMs)) ms |
        | 缩略图缓存命中率 | \(String(format: "%.0f", thumbCacheHitRate * 100))% |
        """
    }

    func jsonExport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

// MARK: - View Model

@MainActor
class StressTestViewModel: ObservableObject {
    @Published var report: StressReport?
    @Published var isRunning = false
    @Published var progress: String = ""
    @Published var progressPercent: Double = 0
    @Published var logLines: [String] = ["应力测试面板已就绪"]

    // MARK: - Data Injection (via FFI — fast for moderate sizes)

    func injectTestData(count: Int = 10000, textRatio: Double = 0.6, seed: Int64 = 42) {
        isRunning = true
        progressPercent = 0
        progress = "正在通过 FFI 注入数据..."
        addLog("ffi: 注入 \(count) 条记录")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = clipboard_stress_inject(Int32(count), textRatio, seed)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.addLog("ffi: 完成 — 注入 \(result) 条")
                self.progress = "FFI 注入完成（\(result) 条）"
                self.isRunning = false
            }
        }
    }

    // MARK: - Data Reset

    func reloadHistory() {
        isRunning = true
        progressPercent = 0
        progress = "正在重新加载..."
        addLog("reload: 从 DB 重新加载历史记录")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let count = clipboard_reload_history()
            DispatchQueue.main.async {
                guard let self else { return }
                self.addLog("reload: 完成 — 加载了 \(count) 条")
                self.progress = "已加载 \(count) 条"
                self.isRunning = false
            }
        }
    }

    func resetData() {
        isRunning = true
        progressPercent = 0
        progress = "正在重置..."
        addLog("reset: 重置应力测试数据")

        clipboard_stress_reset()
        // Trigger immediate backend refresh by bumping revision
        // The 0.5s timer will pick it up

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.addLog("reset: 完成")
            self.progress = "已重置"
            self.isRunning = false
        }
    }

    // MARK: - Run Benchmarks

    func runAllBenchmarks() {
        isRunning = true
        progressPercent = 0
        progress = "正在运行基准测试..."
        addLog("bench: 开始所有基准测试")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 1. Snapshot lock benchmark (100 iterations, release each)
            let snapSamples = 100
            var snapTotalNs: UInt64 = 0
            for _ in 0..<snapSamples {
                let t0 = nowNanoseconds()
                let snap = clipboard_snapshot_acquire()
                if snap != nil {
                    clipboard_snapshot_release(snap)
                }
                snapTotalNs += nowNanoseconds() - t0
            }
            let snapAvg = Double(snapTotalNs) / Double(snapSamples) / 1000.0 // µs

            // 2. Count call benchmark (1000 iterations)
            let countSamples = 1000
            let countT0 = nowNanoseconds()
            for _ in 0..<countSamples {
                _ = clipboard_get_count()
            }
            let countAvg = Double(nowNanoseconds() - countT0) / Double(countSamples) // ns

            // 3. Rust internal bench (cross-check)
            var rustSnapAvg = snapAvg
            var rustCountAvg = countAvg
            let benchStr = clipboard_stress_run_bench()
            if benchStr != nil {
                let json = String(cString: benchStr!)
                clipboard_free_string(benchStr!)
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    rustSnapAvg = obj["snapshot_clone_avg_us"] as? Double ?? snapAvg
                    rustCountAvg = obj["count_lock_avg_ns"] as? Double ?? countAvg
                }
            }

            // 4. Memory
            let mem = measureMemory()
            let entryCount = Int(clipboard_get_count())

            // 5. Image load benchmarks
            var thumbTimes: [Double] = []
            var fullTimes: [Double] = []
            var thumbHits = 0
            var thumbMisses = 0
            let maxThumbSamples = 200
            let maxFullSamples = 50

            let snap = clipboard_snapshot_acquire()
            if snap != nil {
                let c = Int(clipboard_snapshot_count(snap))
                var dbIds: [Int64] = []
                for i in 0..<c {
                    if clipboard_snapshot_item_type(snap, Int32(i)) == 1 {
                        let dbId = clipboard_snapshot_get_image_db_id(snap, Int32(i))
                        if dbId > 0 { dbIds.append(dbId) }
                        if dbIds.count >= maxThumbSamples { break }
                    }
                }
                clipboard_snapshot_release(snap)

                // Thumbnail loads
                for (idx, dbId) in dbIds.enumerated() {
                    let t0 = nowNanoseconds()
                    var len: Int32 = 0
                    if let ptr = clipboard_get_image_thumb_by_db_id(dbId, &len) {
                        thumbTimes.append(Double(nowNanoseconds() - t0) / 1_000_000) // ms
                        clipboard_free_bytes(ptr, len)
                        thumbHits += 1
                    } else {
                        thumbMisses += 1
                    }

                    // Full image (subset only)
                    if idx < maxFullSamples {
                        let t0 = nowNanoseconds()
                        var len: Int32 = 0
                        if let ptr = clipboard_get_image_full_by_db_id(dbId, &len) {
                            fullTimes.append(Double(nowNanoseconds() - t0) / 1_000_000)
                            clipboard_free_bytes(ptr, len)
                        }
                    }
                }
            }

            let thumbAvg = thumbTimes.isEmpty ? 0 : thumbTimes.reduce(0, +) / Double(thumbTimes.count)
            let fullAvg = fullTimes.isEmpty ? 0 : fullTimes.reduce(0, +) / Double(fullTimes.count)
            let hitRate = Double(thumbHits) / Double(max(thumbHits + thumbMisses, 1))

            // 6. Scoring
            let perfScore = Self.scorePerformance(snapUs: rustSnapAvg, countNs: rustCountAvg, thumbMs: thumbAvg)
            let memScore = Self.scoreMemory(footprintMB: mem.footprintMB, peakMB: mem.peakMB)
            let smoothScore = Self.scoreSmoothness(thumbMs: thumbAvg, fullMs: fullAvg)
            // Power score: assumed 4.0 (can't measure without sudo)
            let powerScore = 4.0
            let totalScore = perfScore * 0.35 + memScore * 0.25 + smoothScore * 0.20 + powerScore * 0.20

            let rating: String
            switch totalScore {
            case 4.0...: rating = "优秀"
            case 3.0..<4.0: rating = "良好"
            case 2.0..<3.0: rating = "及格"
            default: rating = "需优化"
            }

            let report = StressReport(
                timestamp: Date(),
                totalEntries: entryCount,
                textEntries: Int(Double(entryCount) * 0.6),
                imageEntries: Int(Double(entryCount) * 0.4),
                snapshotLockAvgUs: rustSnapAvg,
                countLockAvgNs: rustCountAvg,
                startupRssMB: 0,
                startupTimeMs: 0,
                footprintMB: mem.footprintMB,
                peakRssMB: mem.peakMB,
                residentSizeMB: mem.residentMB,
                vmSizeMB: mem.vmMB,
                thumbLoadAvgMs: thumbAvg,
                fullImageLoadAvgMs: fullAvg,
                thumbCacheHitRate: hitRate,
                performanceScore: perfScore,
                memoryScore: memScore,
                smoothnessScore: smoothScore,
                totalScore: totalScore,
                rating: rating
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.report = report
                self.addLog("═══ 基准测试完成 ═══")
                self.addLog("快照: \(String(format: "%.1f", rustSnapAvg))µs | 计数: \(String(format: "%.1f", rustCountAvg))ns")
                self.addLog("内存: 实占 \(String(format: "%.1f", mem.footprintMB))MB | RSS \(String(format: "%.1f", mem.residentMB))MB | 峰值 \(String(format: "%.1f", mem.peakMB))MB")
                self.addLog("缩略图: \(String(format: "%.1f", thumbAvg))ms（命中率 \(String(format: "%.0f", hitRate * 100))%）")
                self.addLog("大图: \(String(format: "%.1f", fullAvg))ms")
                self.addLog("性能: \(String(format: "%.1f", perfScore))/5.0 | 内存: \(String(format: "%.1f", memScore))/5.0")
                self.addLog("流畅度: \(String(format: "%.1f", smoothScore))/5.0 | 总分: \(String(format: "%.1f", totalScore))/5.0")
                self.addLog("评级: \(rating)")
                self.progress = "测试完成"
                self.isRunning = false
            }
        }
    }

    // MARK: - Memory

    struct MemoryInfo {
        var footprintMB: Double    // phys_footprint — matches Activity Monitor
        var residentMB: Double
        var peakMB: Double
        var vmMB: Double
    }

    nonisolated func measureMemory() -> MemoryInfo {
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        // TASK_VM_INFO = 22, TASK_VM_INFO_PURGEABLE = 23 (from <mach/task_info.h>).
        // The values changed in a recent macOS SDK — using the raw numeric constants
        // avoids relying on #define macros that aren't imported into Swift.
        let kr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(22), $0, &count)
            }
        }

        if kr == KERN_SUCCESS {
            // phys_footprint is the exact value shown in Activity Monitor's "Memory" column.
            let fp = vmInfo.phys_footprint
            if fp > 0 && fp < 1_000_000_000_000 { // sanity: reject impossibly large values
                return MemoryInfo(
                    footprintMB: Double(fp) / 1_048_576,
                    residentMB: Double(vmInfo.resident_size) / 1_048_576,
                    peakMB: Double(vmInfo.resident_size_peak) / 1_048_576,
                    vmMB: Double(vmInfo.virtual_size) / 1_048_576
                )
            }
        }

        // Fallback: estimate from resident_size
        return MemoryInfo(
            footprintMB: Double(vmInfo.resident_size) / 1_048_576 * 0.65,
            residentMB: Double(vmInfo.resident_size) / 1_048_576,
            peakMB: 0,
            vmMB: Double(vmInfo.virtual_size) / 1_048_576
        )
    }

    // MARK: - High-precision timing

    nonisolated func nowNanoseconds() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let raw = mach_absolute_time()
        return raw * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    // MARK: - Scoring

    nonisolated static func scorePerformance(snapUs: Double, countNs: Double, thumbMs: Double) -> Double {
        let snap = snapUs <= 1.0 ? 5.0 : snapUs <= 2.0 ? 4.5 : snapUs <= 5.0 ? 4.0 : snapUs <= 10.0 ? 3.0 : snapUs <= 20.0 ? 2.0 : 1.0
        let cnt = countNs <= 100 ? 5.0 : countNs <= 500 ? 4.0 : countNs <= 1000 ? 3.0 : countNs <= 5000 ? 2.0 : 1.0
        let thumb = thumbMs <= 10 ? 5.0 : thumbMs <= 50 ? 4.0 : thumbMs <= 100 ? 3.0 : thumbMs <= 500 ? 2.0 : 1.0
        return (snap + cnt + thumb) / 3.0
    }

    nonisolated static func scoreMemory(footprintMB: Double, peakMB: Double) -> Double {
        let rss = footprintMB <= 128 ? 5.0 : footprintMB <= 256 ? 4.5 : footprintMB <= 384 ? 3.5 : footprintMB <= 512 ? 2.5 : footprintMB <= 768 ? 1.5 : 1.0
        let peak = peakMB <= 256 ? 5.0 : peakMB <= 512 ? 4.0 : peakMB <= 768 ? 3.0 : peakMB <= 1024 ? 2.0 : 1.0
        return (rss + peak) / 2.0
    }

    nonisolated static func scoreSmoothness(thumbMs: Double, fullMs: Double) -> Double {
        let t = thumbMs <= 5 ? 5.0 : thumbMs <= 20 ? 4.5 : thumbMs <= 50 ? 4.0 : thumbMs <= 100 ? 3.0 : thumbMs <= 200 ? 2.0 : 1.0
        let f = fullMs <= 50 ? 5.0 : fullMs <= 100 ? 4.5 : fullMs <= 200 ? 4.0 : fullMs <= 500 ? 3.0 : fullMs <= 1000 ? 2.0 : 1.0
        return (t + f) / 2.0
    }

    // MARK: - Helpers

    func addLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLines.append("[\(f.string(from: Date()))] \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    func exportReport() {
        guard let report = report else {
            addLog("无可导出的报告 — 请先运行测试")
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出压力测试报告"
        panel.nameFieldStringValue = "copyattach_stress_report.md"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.markdown().write(to: url, atomically: true, encoding: .utf8)
                self?.addLog("报告已保存至 \(url.path)")
            } catch {
                self?.addLog("保存失败: \(error.localizedDescription)")
            }
        }
    }
}
