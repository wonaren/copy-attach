import AppKit
import SwiftUI

// MARK: - Stress Test Panel

struct StressTestPanel: View {
    @State private var vm = StressTestViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                divider
                dataSection
                divider
                benchmarkSection
                divider
                resultsSection
                divider
                logSection
            }
            .padding(20)
        }
        .frame(width: 580, height: 700)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    var headerSection: some View {
        HStack {
            Image(systemName: "ant")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("应力测试面板")
                .font(.headline)
            Spacer()
            if vm.isRunning {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 4)
                Text(vm.progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var divider: some View {
        Divider()
    }

    // MARK: - Data

    var dataSection: some View {
        GroupBox(label: Label("测试数据", systemImage: "cylinder")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("注入 10,000 条") {
                        vm.injectTestData()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isRunning)

                    Button("注入 1,000 条") {
                        vm.injectTestData(count: 1000)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isRunning)
                }

                HStack(spacing: 10) {
                    Button("重置数据") {
                        vm.resetData()
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isRunning)

                    Button("重新加载（阈值 10000）") {
                        // Set threshold to 10000 then reload history from DB
                        UserDefaults.standard.set(10000, forKey: "CleanupThreshold")
                        clipboard_set_cleanup_threshold(10000)
                        vm.reloadHistory()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(vm.isRunning)
                }

                Text("直接通过 FFI 在进程内生成数据，无需外部依赖。CLI 方式已废弃，改用此方式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Benchmark

    var benchmarkSection: some View {
        GroupBox(label: Label("基准测试", systemImage: "chart.bar")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("运行全部测试") {
                        vm.runAllBenchmarks()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(vm.isRunning)

                    if vm.report != nil {
                        Button("导出报告") {
                            vm.exportReport()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("测量指标：快照耗时、锁定开销、内存占用（RSS/峰值）、图片加载延迟、综合评分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Results

    @ViewBuilder
    var resultsSection: some View {
        if let report = vm.report {
            GroupBox(label: Label("测试结果", systemImage: "checkmark.circle")) {
                VStack(alignment: .leading, spacing: 6) {
                    ScoreRow(title: "性能（35%）", score: report.performanceScore, maxScore: 5.0,
                             detail: "快照 \(String(format: "%.1f", report.snapshotLockAvgUs))µs")
                    ScoreRow(title: "内存（25%）", score: report.memoryScore, maxScore: 5.0,
                             detail: "实占内存 \(String(format: "%.1f", report.footprintMB))MB")
                    ScoreRow(title: "流畅度（20%）", score: report.smoothnessScore, maxScore: 5.0,
                             detail: "缩略图 \(String(format: "%.1f", report.thumbLoadAvgMs))ms")
                    ScoreRow(title: "功耗（20%）", score: 4.0, maxScore: 5.0,
                             detail: "假设值（需 sudo powermetrics）")

                    HStack {
                        Text("总分")
                            .fontWeight(.bold)
                        Spacer()
                        Text(String(format: "%.1f/5.0", report.totalScore))
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(report.totalScore >= 4.0 ? .green : report.totalScore >= 3.0 ? .yellow : .red)
                        Text(report.rating)
                            .font(.headline)
                            .foregroundStyle(report.totalScore >= 4.0 ? .green : report.totalScore >= 3.0 ? .orange : .red)
                    }
                    .padding(.top, 4)

                    HStack(spacing: 16) {
                        StatBadge(value: "\(report.totalEntries)", label: "条目")
                        StatBadge(value: "\(String(format: "%.0f", report.footprintMB))MB", label: "实占内存")
                        StatBadge(value: "\(String(format: "%.1f", report.thumbLoadAvgMs))ms", label: "缩略图")
                    }
                    .padding(.top, 4)
                }
                .padding(8)
            }
        }
    }

    // MARK: - Log

    var logSection: some View {
        GroupBox(label: Label("日志", systemImage: "text.alignleft")) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Color.clear.id("log_bottom")
                    }
                }
                .frame(height: 140)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .onChange(of: vm.logLines.count) {
                    withAnimation { proxy.scrollTo("log_bottom", anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Sub-views

private struct ScoreRow: View {
    let title: String
    let score: Double
    let maxScore: Double
    let detail: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f/%.0f", score, maxScore))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(score >= 4.0 ? .green : score >= 3.0 ? .orange : .red)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

private struct StatBadge: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - Window Controller

class StressTestWindowController: NSWindowController {
    convenience init() {
        let view = StressTestPanel()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 580, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CopyAttach 压力测试"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
