import AppKit
import Foundation
import Observation

// MARK: - Onboarding Steps

/// The core CopyAttach operations the guided tour walks through, in order.
///
/// Every step maps to one real user action inside the popup or the system, so
/// finishing the tour proves the user actually exercised the feature instead of
/// only reading about it. Steps are strictly sequential: `record(_:)` advances
/// only when the reported action matches the current step, which keeps the
/// instruction on screen and the action the user performs in lockstep.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case copyContent
    case openPopup
    case search
    case preview
    case favorite
    case deleteAndUndo
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
            return "选中一条记录按 ⌃⌫ 删除；删错了按 ⌘Z 撤销。"
        case .paste:
            return "把要用的记录直接拖到需要的地方（编辑器、文档或聊天窗口），松手就能贴进去。"
        }
    }

    /// Static key badge. `.openPopup` returns nil because its hint is the
    /// user's recorded hotkey, supplied by the guide view.
    var keyHint: String? {
        switch self {
        case .preview: return "Space"
        case .favorite: return "⌥P"
        case .deleteAndUndo: return "⌃⌫ / ⌘Z"
        // Dragging is a gesture, not a shortcut — the instruction carries it.
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
        case .paste: return "hand.draw"
        }
    }
}

// MARK: - Onboarding Phase

/// Which shape the tour surface is in.
///
/// The tour is a *single* window that changes shape: it opens as a centered
/// welcome card and, on 「开始引导」, shrinks into the corner progress card. One
/// window is what makes the transition continuous — a second window appearing
/// in the corner reads as coming out of nowhere.
enum OnboardingPhase: Equatable {
    case welcome
    case guiding
}

// MARK: - Onboarding Events

/// A real user action observed on the popup / backend paths. Reported through
/// `OnboardingGuide.record(_:)`, which advances the tour when the action is the
/// one the current step asks for.
enum OnboardingEvent {
    case copied
    case popupOpened
    case searched
    case previewed
    case favorited
    case deleted
    case undone
    /// A native item drag finished — the tour's last step.
    case dragged
}

// MARK: - Onboarding Guide

/// First-run guided tour over the core clipboard workflow.
///
/// The guide owns its own progress state and a floating non-key panel; the
/// rest of the app only reports events (`record(_:)`) and kicks it off when the
/// backend becomes live. Progress is persisted so quitting mid-tour resumes
/// where the user left off, while completing or skipping suppresses the tour
/// for future launches.
@MainActor
@Observable
final class OnboardingGuide {
    static let shared = OnboardingGuide()

    /// Set once the tour is finished or explicitly skipped; suppresses auto-start.
    private static let completedKey = "OnboardingCompleted"
    /// Raw values of the steps already done, so a relaunch resumes mid-tour.
    private static let progressKey = "OnboardingProgress"

    /// True while the tour is on screen (including the completion celebration).
    private(set) var isActive = false
    /// Welcome card or progress card. Nil when the tour is not running.
    private(set) var phase: OnboardingPhase?
    private(set) var completedSteps: Set<OnboardingStep> = []
    /// Sub-action flags for the combined delete/undo step.
    private(set) var deleteActionDone = false
    private(set) var undoActionDone = false

    private var panel: OnboardingGuidePanel?
    private var spotlight: SpotlightOverlayWindow?
    /// Target control geometry reported by the popup, in its hosting space.
    private var spotlightGeometry = SpotlightGeometry()
    /// Last place the selected row was seen. A row stops reporting once the
    /// lazy stack recycles it, which must not be mistaken for "nothing is
    /// selected" — that would snap the cutout out to the whole list mid-scroll.
    private var lastRowRect: CGRect?
    /// What the cutout is currently on, to tell a step change from a move.
    private var lastFocusKind: SpotlightFocusKind?
    /// True while the user is dragging an item out of the popup.
    private var isItemDragInProgress = false
    /// Follows the popup while the user drags it, so the cutout stays on it.
    private var popupMoveObserver: NSObjectProtocol?
    private var copyBaselineRevision: UInt64 = 0
    private var copyPollTimer: Timer?

    private init() {}

    // MARK: - Derived State

    /// The first step the user has not completed, or nil when all are done.
    ///
    /// Nil during the welcome phase: the tour has not started, so there is no
    /// step to show and nothing to point the spotlight at.
    var currentStep: OnboardingStep? {
        guard isActive, phase == .guiding else { return nil }
        return OnboardingStep.allCases.first { !completedSteps.contains($0) }
    }

    var totalStepCount: Int { OnboardingStep.allCases.count }

    /// The control inside the popup the current step points at, if any.
    ///
    /// Doubles as the gate for the spotlight scrim: with no target there is
    /// nothing to point at, and dimming the display while the user works in
    /// another app would fight the very step (copying) being asked for.
    var spotlightTarget: SpotlightTarget? {
        guard let step = currentStep else { return nil }
        switch step {
        case .search: return .searchField
        // These steps all act on the entry under the cursor, so the cutout
        // rides the selected row and follows ↑/↓ — the strongest possible
        // statement of "this one".
        case .preview, .favorite, .deleteAndUndo, .paste: return .selectedRow
        case .copyContent, .openPopup: return nil
        }
    }

    // MARK: - Lifecycle

    /// Auto-start hook, called once the Rust backend is up. A finished tour
    /// stays finished; a partially completed one resumes.
    func startIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        start(resetProgress: false)
    }

    /// Menu-bar entry point: replay the tour from the first step.
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

    /// Tear down timers/panel at app termination.
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
            persistProgress()
            // A fresh run must not reuse geometry measured for the last one.
            resetReportedGeometry()
        } else {
            loadProgress()
        }

        guard completedSteps.count < OnboardingStep.allCases.count else {
            // Progress recorded a full tour without the completion flag (e.g. the
            // app was killed during the celebration). Treat it as done.
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            return
        }

        isActive = true
        deleteActionDone = false
        undoActionDone = false
        // A drag left in flight by a previous run would keep the scrim hidden.
        isItemDragInProgress = false

        // A brand-new user meets the welcome card first; someone resuming a
        // partly finished tour goes straight back to the progress card.
        phase = completedSteps.isEmpty ? .welcome : .guiding
        if panel?.isVisible == true {
            // Restarted while the window is still up: morph back to the welcome
            // shape rather than snapping.
            morphPanel()
        } else {
            showPanel()
        }
        if phase == .guiding { startCopyPollingIfNeeded() }
        debugLog("Onboarding guide started at step \(completedSteps.count + 1)/\(OnboardingStep.allCases.count)")
    }

    /// Welcome card 「开始引导」: morph the window into the progress card and
    /// start watching for the first step.
    func beginTour() {
        guard isActive, phase == .welcome else { return }
        debugLog("Onboarding guide: welcome card accepted")
        phase = .guiding
        morphPanel()
        startCopyPollingIfNeeded()
    }

    /// Finish (all steps done) or skip: persist completion and hide the panel.
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

    // MARK: - Event Reporting

    /// Report a real user action. Only the action the current step asks for
    /// advances the tour; anything else is ignored so the narrative stays
    /// coherent.
    func record(_ event: OnboardingEvent) {
        guard isActive, let step = currentStep else { return }
        switch (step, event) {
        case (.copyContent, .copied):
            complete(step)
            // The user may have opened the popup before copying. Asking them to
            // close and reopen it would be busywork — the step is already
            // satisfied by the window being on screen.
            if HistoryPopupWindow.existing?.isVisible == true { record(.popupOpened) }
        case (.openPopup, .popupOpened),
             (.search, .searched),
             (.preview, .previewed),
             (.favorite, .favorited),
             (.paste, .dragged):
            complete(step)
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
            // Only half the step landed — repaint so the card shows which half.
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

        // The last step is paste: the content has already landed in the user's
        // app, so the tour gets out of the way right away instead of sitting on
        // top of whatever they want to do next.
        if completedSteps.count == OnboardingStep.allCases.count {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            teardown()
            return
        }
        refreshPanel()
    }

    /// Arm the clipboard watch for the first step.
    ///
    /// That step is the only one performed with no popup on screen, and the
    /// only one that needs a poll to detect it.
    private func startCopyPollingIfNeeded() {
        guard !completedSteps.contains(.copyContent) else { return }
        copyBaselineRevision = clipboard_get_history_revision()
        beginCopyPolling()
    }



    // MARK: - Progress Persistence

    private func loadProgress() {
        let raw = UserDefaults.standard.array(forKey: Self.progressKey) as? [Int] ?? []
        completedSteps = Set(raw.compactMap(OnboardingStep.init(rawValue:)))
    }

    private func persistProgress() {
        UserDefaults.standard.set(completedSteps.map(\.rawValue), forKey: Self.progressKey)
    }

    // MARK: - Copy Detection
    //
    // The first step happens outside the popup, where the app's UI poll is
    // stopped by design. The history revision is a pure FFI atomic, so a 0.5s
    // watch is effectively free — and it stops itself as soon as the step is
    // done (or the tour moves on).

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

    // MARK: - Panel

    private func showPanel() {
        let panel = self.panel ?? OnboardingGuidePanel()
        self.panel = panel
        let focus = spotlightFocus()
        panel.update(guide: self, focus: focus?.rect, morph: false)
        panel.orderFrontRegardless()
        applySpotlight(focus)
    }

    /// Repaint the card and re-park it beside the current target.
    private func refreshPanel() {
        let focus = spotlightFocus()
        panel?.update(guide: self, focus: focus?.rect, morph: false)
        applySpotlight(focus)
    }

    /// Welcome card → progress card. The window slides and resizes to its new
    /// place in one continuous animation while its content cross-fades, so the
    /// corner card is visibly the welcome card shrinking away rather than a
    /// new window appearing out of nowhere.
    private func morphPanel() {
        let focus = spotlightFocus()
        panel?.update(guide: self, focus: focus?.rect, morph: true)
        applySpotlight(focus)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Spotlight

    /// What the cutout is currently locked onto.
    ///
    /// Distinguishes a *step* change from the target merely moving underneath
    /// the cutout: the former earns the travel animation that steers the eye,
    /// the latter must land exactly or it would trail the row it is framing.
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

    /// Sync the spotlight cutout with the control the current step points at.
    ///
    /// Callers are the guide's own state changes plus every event that can move
    /// or hide the popup and the preview panel. The guide card is deliberately
    /// left alone here: it must not chase the popup while the user drags it.
    func refreshSpotlight() {
        applySpotlight(spotlightFocus())
    }

    /// Geometry reported by the popup, in its SwiftUI (hosting) coordinate
    /// space. Reported only while the tour is running.
    func updateSpotlightGeometry(_ geometry: SpotlightGeometry) {
        guard geometry != spotlightGeometry else { return }
        spotlightGeometry = geometry
        // Fresh layout: land the cutout exactly rather than easing into place.
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

    /// The screen rect to light up, the corner to trace it with, and what it is.
    ///
    /// Nil when there is nothing to point at (see `spotlightTarget`), or when
    /// the popup has not reported the target's geometry yet. In the latter case
    /// the spotlight waits for the next layout pass instead of lighting the
    /// whole popup and then contracting onto the control: that two-step read as
    /// a jarring jump right as the popup opened.
    private func spotlightFocus() -> SpotlightFocus? {
        // While an item is in flight the user has to see the whole screen to
        // pick a drop target; dimming everything outside the popup would fight
        // the very gesture the step is teaching.
        guard !isItemDragInProgress else { return nil }
        guard let target = spotlightTarget else { return nil }
        guard let popup = HistoryPopupWindow.existing, popup.isVisible else { return nil }

        // The preview panel covers the popup; while it is up it *is* the thing
        // to look at, and it sits below the scrim on its own level.
        if let preview = popup.previewPanel, preview.isVisible {
            return SpotlightFocus(rect: preview.frame, cornerRadius: 12, kind: .preview)
        }

        if target == .selectedRow {
            if let local = spotlightGeometry.frames[.selectedRow] {
                lastRowRect = local
                return rowFocus(local, in: popup)
            }
            // The row is outside the viewport (scrolling, or the lazy stack
            // recycled it). Hold the cutout where it was last seen rather than
            // blowing it back up to the whole list.
            if spotlightGeometry.hasSelectedRow, let local = lastRowRect {
                return rowFocus(local, in: popup)
            }
            // Nothing is selected at all (the search field owns focus) — point
            // at the list until the user picks a row.
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

    /// Hosting space (origin top-left, y down) → screen space.
    private func screenRect(_ local: CGRect, in window: NSWindow) -> NSRect {
        let frame = window.frame
        return NSRect(
            x: frame.minX + local.minX,
            y: frame.maxY - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    /// Track a native item drag so the scrim can step out of its way.
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

    /// Drop everything the popup measured for the tour.
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
                // No easing while dragging: the hole must stay welded to the window.
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
