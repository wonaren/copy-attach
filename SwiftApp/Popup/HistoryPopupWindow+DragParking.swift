import AppKit
import SwiftUI

// MARK: - Drag anti-occlusion parking mechanics

/// Edge the popup is parked at during an item drag (nil = centered).
/// Shared with `HistoryPopupWindow` (the stored `parkedSide` state).
enum ParkSide {
    case left, right
}

extension HistoryPopupWindow {
    /// Continuous direction tracking during a drag. Each watcher tick adds the
    /// horizontal mouse travel to an accumulator; once the accumulated travel
    /// crosses `dragOcclusionThreshold` the popup parks at the edge opposite
    /// the drag direction and the accumulator restarts. Reversing beyond the
    /// same threshold flips the popup to the other edge. Jitter below the
    /// threshold never triggers anything, and because the accumulator is
    /// zeroed on every flip, wiggling in place cannot oscillate the popup.
    func tickDragParking() {
        let mouseX = NSEvent.mouseLocation.x
        defer { lastDragMouseX = mouseX }
        guard let lastX = lastDragMouseX else { return }
        let dx = mouseX - lastX
        // A jump this large is a coordinate-space discontinuity (e.g. a screen
        // configuration change mid-drag), not mouse travel; restart the run.
        guard abs(dx) < 400 else {
            dragDxAccum = 0
            return
        }
        dragDxAccum += dx

        let threshold = Self.dragOcclusionThreshold
        switch parkedSide {
        case nil:
            if dragDxAccum >= threshold {
                park(at: .left)          // heading right → get out of the way left
            } else if dragDxAccum <= -threshold {
                park(at: .right)         // heading left → get out of the way right
            }
        case .left:
            // Reversed course: accumulated leftward travel beyond the
            // threshold flips the popup to the right edge. Same-direction
            // (rightward) drift must not tax that accumulation — after a long
            // same-direction run, a partial reversal would otherwise need to
            // out-travel the whole run before flipping, leaving the popup
            // parked exactly over the new drop target.
            dragDxAccum = min(dragDxAccum, 0)
            if dragDxAccum <= -threshold { park(at: .right) }
        case .right:
            dragDxAccum = max(dragDxAccum, 0)
            if dragDxAccum >= threshold { park(at: .left) }
        }
    }

    /// Animates the popup to the fixed position at the given edge of its
    /// screen (same y — the popup only slides sideways, never jumps
    /// vertically).
    func park(at side: ParkSide) {
        parkedSide = side
        dragDxAccum = 0
        guard let screen = self.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let targetX: CGFloat
        switch side {
        case .left:
            targetX = visible.minX + Self.dragParkMargin
        case .right:
            targetX = visible.maxX - self.frame.width - Self.dragParkMargin
        }
        let clampedX = min(max(targetX, visible.minX), visible.maxX - self.frame.width)
        let origin = self.frame.origin
        guard abs(origin.x - clampedX) > 1 else { return }
        pendingParkTargetX = clampedX
        lastParkTickX = origin.x
        parkSlideStallTicks = 0
        debugLog("Drag parking: \(side == .left ? "left" : "right") edge")
        // NB: `animator().setFrameOrigin` does not animate (silently no-ops on
        // borderless panels); `animator().setFrame(_:display:)` is the API that
        // actually slides the window.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.dragParkDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(
                NSRect(x: clampedX, y: origin.y, width: self.frame.width, height: self.frame.height),
                display: true
            )
        }
    }

    /// Watches the park slide make progress. Window frame animations are CA
    /// transactions, which can stall while the run loop is in event tracking
    /// mode (the same constraint that motivates closeWithAnimation's
    /// guarantee timer); a stalled slide would leave the popup blocking the
    /// drag path. If the frame has not moved for three consecutive ticks,
    /// land the window directly.
    func tickParkingSlide() {
        guard let target = pendingParkTargetX else { return }
        let x = self.frame.origin.x
        if abs(x - target) < 1 {
            pendingParkTargetX = nil
            parkSlideStallTicks = 0
            return
        }
        if let lastX = lastParkTickX, abs(x - lastX) < 0.5 {
            parkSlideStallTicks += 1
            if parkSlideStallTicks >= 3 {
                debugLog("Drag parking: slide stalled, snapping to edge")
                self.setFrameOrigin(NSPoint(x: target, y: self.frame.origin.y))
                pendingParkTargetX = nil
                parkSlideStallTicks = 0
            }
        } else {
            parkSlideStallTicks = 0
        }
        lastParkTickX = x
    }

    /// Slides the popup back to its centered position when a drag ends with
    /// the popup still open (close-after-drag disabled) — the popup only
    /// parks while a drag is actually in flight.
    func restoreFromParking() {
        resetDragParking()
        guard let screen = self.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let centeredX = visible.minX + (visible.size.width - self.frame.width) / 2
        let origin = self.frame.origin
        guard abs(origin.x - centeredX) > 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.dragParkDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(
                NSRect(x: centeredX, y: origin.y, width: self.frame.width, height: self.frame.height),
                display: true
            )
        }
    }

    func resetDragParking() {
        parkedSide = nil
        dragDxAccum = 0
        lastDragMouseX = nil
        pendingParkTargetX = nil
        lastParkTickX = nil
        parkSlideStallTicks = 0
    }
}
