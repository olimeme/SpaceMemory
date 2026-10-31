import CoreGraphics
import Foundation

/// Detects several direction changes along one axis within a short time.
struct ShakeDetector {
    private let minimumTravel: CGFloat = 35
    private let reversalsNeeded = 4
    private let window: TimeInterval = 0.8

    private struct Axis {
        var anchor: CGFloat
        var direction: CGFloat = 0
        var reversals: [TimeInterval] = []
    }

    private var x: Axis?
    private var y: Axis?

    mutating func reset() {
        x = nil
        y = nil
    }

    func mightBeShaking(at time: TimeInterval) -> Bool {
        [x, y].contains { axis in axis?.reversals.contains { time - $0 <= window } ?? false }
    }

    /// Returns true when this movement completes a shake.
    mutating func add(_ point: CGPoint, time: TimeInterval) -> Bool {
        var axisX = x ?? Axis(anchor: point.x)
        var axisY = y ?? Axis(anchor: point.y)
        let shook = update(&axisX, value: point.x, time: time) || update(&axisY, value: point.y, time: time)
        x = axisX
        y = axisY
        if shook { reset() }
        return shook
    }

    private func update(_ axis: inout Axis, value: CGFloat, time: TimeInterval) -> Bool {
        let delta = value - axis.anchor
        if axis.direction == 0 || delta * axis.direction > 0 {
            if abs(delta) > 0 {
                axis.direction = delta > 0 ? 1 : -1
                axis.anchor = value
            }
        } else if abs(delta) >= minimumTravel {
            axis.direction = -axis.direction
            axis.anchor = value
            axis.reversals.append(time)
        }
        axis.reversals.removeAll { time - $0 > window }
        return axis.reversals.count >= reversalsNeeded
    }
}
