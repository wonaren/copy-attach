import AppKit
import SwiftUI

// MARK: - Drag anti-occlusion parking mechanics

/// Edge the popup is parked at during an item drag (nil = centered).
/// Shared with `HistoryPopupWindow` (the stored `parkedSide` state).
enum ParkSide {
    case left, right
}

extension HistoryPopupWindow {
    /// Screen-zone based parking: divides the screen into 45% : 10% : 45%.
    /// Mouse in right 45% (> 55% width) parks popup at left edge;
    /// mouse in left 45% (< 45% width) parks popup at right edge.
    /// Center 10% (45%..55%) and minor movements within the current zone
    /// do not trigger window repositioning.
    func tickDragParking() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0 else { return }

        let mouseX = NSEvent.mouseLocation.x
        let ratio = (mouseX - visible.minX) / visible.width

        if ratio < Self.dragParkLeftZoneRatio {
            park(at: .right)
        } else if ratio > Self.dragParkRightZoneRatio {
            park(at: .left)
        }
    }

    /// Animates the popup to the fixed position at the given edge of its
    /// screen (same y — the popup only slides sideways, never jumps
    /// vertically).
    func park(at side: ParkSide) {
        guard parkedSide != side else { return }
        parkedSide = side
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
        pendingParkTargetX = nil
        lastParkTickX = nil
        parkSlideStallTicks = 0
    }
}
