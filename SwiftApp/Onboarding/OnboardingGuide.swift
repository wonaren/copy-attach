import AppKit
import Foundation
import Observation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case copyContent
    case openPopup
    case search
    case preview
    case favorite
    case deleteAndUndo
    case pasteQueue
    case paste

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .copyContent: return "复制内容"
        case .openPopup: return "唤出历史"
        case .search: return "搜索定位"
        case .preview: return "预览内容"
        case .favorite: return "收藏常用"
        case .deleteAndUndo: return "删除与撤销"
        case .pasteQueue: return "粘贴队列"
        case .paste: return "拖拽粘贴"
        }
    }

    var instruction: String {
        switch self {
        case .copyContent:
            return "在任意应用里复制一段文字或图片，CopyAttach 会自动记录下来。"
        case .openPopup:
            return "按下快捷键，唤出剪贴板历史面板。"
        case .search:
            return "弹窗打开后，在顶部搜索框输入关键词，立即筛选出匹配的记录。"
        case .preview:
            return "用 ↑ ↓ 选中一条记录，按 Space 查看完整内容。"
        case .favorite:
            return "选中一条常用记录，按 ⌥P 收藏，之后可在收藏标签页快速找到。"
        case .deleteAndUndo:
            return "选中一条记录按 ⌃⌫ 删除；删错了按 ⌘Z 撤销，可连续撤销多次。"
        case .pasteQueue:
            return "选中记录按 ⌘C 加入粘贴队列标号；多选后按 ⏎ 即可在外部用 ⌘V 顺序粘贴。"
        case .paste:
            return "唤出历史弹窗，把要用的记录直接拖到需要的地方（编辑器、文档或聊天窗口），松手就能贴进去。"
        }
    }

    var keyHint: String? {
        switch self {
        case .preview: return "Space"
        case .favorite: return "⌥P"
        case .deleteAndUndo: return "⌃⌫ / ⌘Z"
        case .pasteQueue: return "⌘C / ⏎"
        case .copyContent, .openPopup, .search, .paste: return nil
        }
    }

    var icon: String {
        switch self {
        case .copyContent: return "doc.on.clipboard"
        case .openPopup: return "macwindow"
        case .search: return "magnifyingglass"
        case .preview: return "eye"
        case .favorite: return "star"
        case .deleteAndUndo: return "trash"
        case .pasteQueue: return "list.number"
        case .paste: return "hand.draw"
        }
    }
}

enum OnboardingPhase: Equatable {
    case welcome
    case guiding
}

enum OnboardingEvent {
    case copied
    case popupOpened
    case searched
    case previewed
    case favorited
    case deleted
    case undone
    case queueToggled
    case queueStarted
    case queuePasted
    case dragged
}

@MainActor
@Observable
final class OnboardingGuide {
    static let shared = OnboardingGuide()

    private static let completedKey = "OnboardingCompleted"
    private static let progressKey = "OnboardingProgress"

    private(set) var isActive = false
    private(set) var phase: OnboardingPhase?
    private(set) var completedSteps: Set<OnboardingStep> = []
    private(set) var deleteActionDone = false
    private(set) var undoActionDone = false
    private(set) var queueEnqueueDone = false
    private(set) var queueStartDone = false
    private(set) var queuePasteDone = false

    private var panel: OnboardingGuidePanel?
    private var spotlight: SpotlightOverlayWindow?
    private var spotlightGeometry = SpotlightGeometry()
    private var lastRowRect: CGRect?
    private var lastFocusKind: SpotlightFocusKind?
    private var isItemDragInProgress = false
    private var popupMoveObserver: NSObjectProtocol?
    private var copyBaselineRevision: UInt64 = 0
    private var copyPollTimer: Timer?

    private init() {}

    var currentStep: OnboardingStep? {
        guard isActive, phase == .guiding else { return nil }
        return OnboardingStep.allCases.first { !completedSteps.contains($0) }
    }

    var totalStepCount: Int { OnboardingStep.allCases.count }

    var spotlightTarget: SpotlightTarget? {
        guard let step = currentStep else { return nil }
        switch step {
        case .search: return .searchField
        case .preview, .favorite, .deleteAndUndo, .paste:
            return .selectedRow
        case .pasteQueue:
            return queueStartDone ? nil : .selectedRow
        case .copyContent, .openPopup:
            return nil
        }
    }

    func startIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        start(resetProgress: false)
    }

    func restart() {
        UserDefaults.standard.set(false, forKey: Self.completedKey)
        start(resetProgress: true)
    }

    func skip() {
        guard isActive else { return }
        debugLog(phase == .welcome
                 ? "Onboarding guide declined at the welcome card"
                 : "Onboarding guide skipped at step \(completedSteps.count + 1)")
        teardown()
    }

    func stop() {
        stopCopyPolling()
        closePanel()
        hideSpotlight()
        resetReportedGeometry()
        isActive = false
        phase = nil
    }

    private func start(resetProgress: Bool) {
        if resetProgress {
            completedSteps = []
            deleteActionDone = false
            undoActionDone = false
            queueEnqueueDone = false
            queueStartDone = false
            queuePasteDone = false
            persistProgress()
            resetReportedGeometry()
        } else {
            loadProgress()
        }

        guard completedSteps.count < OnboardingStep.allCases.count else {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            return
        }

        isActive = true
        deleteActionDone = false
        undoActionDone = false
        queueEnqueueDone = false
        queueStartDone = false
        queuePasteDone = false
        isItemDragInProgress = false

        phase = completedSteps.isEmpty ? .welcome : .guiding
        if panel?.isVisible == true {
            morphPanel()
        } else {
            showPanel()
        }
        if phase == .guiding { startCopyPollingIfNeeded() }
        debugLog("Onboarding guide started at step \(completedSteps.count + 1)/\(OnboardingStep.allCases.count)")
    }

    func beginTour() {
        guard isActive, phase == .welcome else { return }
        debugLog("Onboarding guide: welcome card accepted")
        phase = .guiding
        morphPanel()
        startCopyPollingIfNeeded()
    }

    private func teardown() {
        isActive = false
        phase = nil
        stopCopyPolling()
        closePanel()
        hideSpotlight()
        resetReportedGeometry()
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.removeObject(forKey: Self.progressKey)
        debugLog("Onboarding guide finished")
    }

    func record(_ event: OnboardingEvent) {
        guard isActive, let step = currentStep else { return }
        switch (step, event) {
        case (.copyContent, .copied):
            complete(step)
            if HistoryPopupWindow.existing?.isVisible == true { record(.popupOpened) }
        case (.openPopup, .popupOpened),
             (.search, .searched),
             (.preview, .previewed),
             (.favorite, .favorited),
             (.paste, .dragged):
            complete(step)
        case (.pasteQueue, .queueToggled):
            queueEnqueueDone = PasteQueueManager.shared.hasItems
            refreshPanel()
        case (.pasteQueue, .queueStarted):
            queueEnqueueDone = true
            queueStartDone = true
            refreshPanel()
        case (.pasteQueue, .queuePasted):
            queueEnqueueDone = true
            queueStartDone = true
            queuePasteDone = true
            complete(.pasteQueue)
        case (.deleteAndUndo, .deleted):
            deleteActionDone = true
            completeDeleteAndUndoIfReady()
        case (.deleteAndUndo, .undone):
            undoActionDone = true
            completeDeleteAndUndoIfReady()
        default:
            break
        }
    }

    private func completeDeleteAndUndoIfReady() {
        guard deleteActionDone && undoActionDone else {
            refreshPanel()
            return
        }
        complete(.deleteAndUndo)
    }

    private func complete(_ step: OnboardingStep) {
        guard !completedSteps.contains(step) else { return }
        completedSteps.insert(step)
        persistProgress()
        debugLog("Onboarding step completed: \(step.title) (\(completedSteps.count)/\(OnboardingStep.allCases.count))")

        if completedSteps.count == OnboardingStep.allCases.count {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            teardown()
            return
        }
        refreshPanel()
    }

    private func startCopyPollingIfNeeded() {
        guard !completedSteps.contains(.copyContent) else { return }
        copyBaselineRevision = clipboard_get_history_revision()
        beginCopyPolling()
    }

    private func loadProgress() {
        let raw = UserDefaults.standard.array(forKey: Self.progressKey) as? [Int] ?? []
        completedSteps = Set(raw.compactMap(OnboardingStep.init(rawValue:)))
    }

    private func persistProgress() {
        UserDefaults.standard.set(completedSteps.map(\.rawValue), forKey: Self.progressKey)
    }

    private func beginCopyPolling() {
        stopCopyPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isActive, self.currentStep == .copyContent else {
                    self.stopCopyPolling()
                    return
                }
                if clipboard_get_history_revision() != self.copyBaselineRevision {
                    self.record(.copied)
                }
            }
        }
        timer.tolerance = 0.1
        copyPollTimer = timer
    }

    private func stopCopyPolling() {
        copyPollTimer?.invalidate()
        copyPollTimer = nil
    }

    private func showPanel() {
        let panel = self.panel ?? OnboardingGuidePanel()
        self.panel = panel
        let focus = spotlightFocus()
        panel.update(guide: self, focus: focus?.rect, morph: false)
        panel.orderFrontRegardless()
        applySpotlight(focus)
    }

    private func refreshPanel() {
        let focus = spotlightFocus()
        panel?.update(guide: self, focus: focus?.rect, morph: false)
        applySpotlight(focus)
    }

    private func morphPanel() {
        let focus = spotlightFocus()
        panel?.update(guide: self, focus: focus?.rect, morph: true)
        applySpotlight(focus)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private enum SpotlightFocusKind: Equatable {
        case searchField
        case selectedRow
        case listFallback
        case preview
    }

    private struct SpotlightFocus {
        let rect: NSRect
        let cornerRadius: CGFloat
        let kind: SpotlightFocusKind
    }

    func refreshSpotlight() {
        applySpotlight(spotlightFocus())
    }

    func updateSpotlightGeometry(_ geometry: SpotlightGeometry) {
        guard geometry != spotlightGeometry else { return }
        spotlightGeometry = geometry
        let focus = spotlightFocus()
        applySpotlight(focus)
        panel?.update(guide: self, focus: focus?.rect, morph: false)
    }

    private func applySpotlight(_ focus: SpotlightFocus?) {
        guard let focus else {
            hideSpotlight()
            return
        }
        let screen = HistoryPopupWindow.existing?.screen
            ?? NSScreen.screens.first { $0.frame.intersects(focus.rect) }
            ?? NSScreen.main
        guard let screen else { return }

        let movedToNewTarget = focus.kind != lastFocusKind
        lastFocusKind = focus.kind

        let overlay = spotlight ?? SpotlightOverlayWindow()
        spotlight = overlay
        overlay.present(
            on: screen,
            focus: focus.rect,
            cornerRadius: focus.cornerRadius,
            animated: movedToNewTarget
        )
        installPopupMoveObserver()
    }

    private func spotlightFocus() -> SpotlightFocus? {
        guard !isItemDragInProgress else { return nil }
        guard let target = spotlightTarget else { return nil }
        guard let popup = HistoryPopupWindow.existing, popup.isVisible else { return nil }

        if let preview = popup.previewPanel, preview.isVisible {
            return SpotlightFocus(rect: preview.frame, cornerRadius: 12, kind: .preview)
        }

        if target == .selectedRow {
            if let local = spotlightGeometry.frames[.selectedRow] {
                lastRowRect = local
                return rowFocus(local, in: popup)
            }
            if spotlightGeometry.hasSelectedRow, let local = lastRowRect {
                return rowFocus(local, in: popup)
            }
            if let local = spotlightGeometry.frames[.list] {
                return SpotlightFocus(
                    rect: screenRect(local, in: popup),
                    cornerRadius: SpotlightTarget.list.cornerRadius,
                    kind: .listFallback
                )
            }
            return nil
        }

        if let local = spotlightGeometry.frames[target] {
            return SpotlightFocus(
                rect: screenRect(local, in: popup),
                cornerRadius: target.cornerRadius,
                kind: .searchField
            )
        }
        return nil
    }

    private func rowFocus(_ local: CGRect, in popup: HistoryPopupWindow) -> SpotlightFocus {
        SpotlightFocus(
            rect: screenRect(local, in: popup),
            cornerRadius: SpotlightTarget.selectedRow.cornerRadius,
            kind: .selectedRow
        )
    }

    private func screenRect(_ local: CGRect, in window: NSWindow) -> NSRect {
        let frame = window.frame
        return NSRect(
            x: frame.minX + local.minX,
            y: frame.maxY - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    func setItemDragInProgress(_ inProgress: Bool) {
        guard isItemDragInProgress != inProgress else { return }
        isItemDragInProgress = inProgress
        refreshSpotlight()
    }

    private func hideSpotlight() {
        spotlight?.hide()
        spotlight = nil
        lastFocusKind = nil
        removePopupMoveObserver()
    }

    private func resetReportedGeometry() {
        spotlightGeometry = SpotlightGeometry()
        lastRowRect = nil
    }

    private func installPopupMoveObserver() {
        guard popupMoveObserver == nil else { return }
        guard let popup = HistoryPopupWindow.existing else { return }
        popupMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: popup,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSpotlight()
            }
        }
    }

    private func removePopupMoveObserver() {
        if let popupMoveObserver {
            NotificationCenter.default.removeObserver(popupMoveObserver)
        }
        popupMoveObserver = nil
    }
}
