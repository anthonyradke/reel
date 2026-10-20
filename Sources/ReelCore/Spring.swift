import Foundation

/// A critically damped spring. It never overshoots, and retargeting it mid-flight keeps the
/// current velocity, so a second key press while the strip is still moving feels continuous.
public struct Spring: Equatable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double
    /// Angular frequency. About 20 settles in roughly a quarter of a second.
    public var omega: Double

    public init(_ value: Double, omega: Double = 22) {
        self.value = value
        self.target = value
        self.omega = omega
    }

    public var isSettled: Bool { value == target && velocity == 0 }

    /// Advances by `dt` seconds. Returns false once it has come to rest.
    @discardableResult
    public mutating func step(_ dt: Double) -> Bool {
        if isSettled { return false }
        let dt = min(max(dt, 0), 0.1)
        let d = value - target
        let e = exp(-omega * dt)
        let a = (velocity + omega * d) * dt
        value = target + (d + a) * e
        velocity = (velocity - (velocity + omega * d) * omega * dt) * e
        if abs(value - target) < 0.25 && abs(velocity) < 2 {
            snap()
            return false
        }
        return true
    }

    public mutating func snap() {
        value = target
        velocity = 0
    }

    /// Where the spring would come to rest if released now with its velocity and no target pull.
    /// Used to throw the strip after a swipe.
    public static func projectedRest(value: Double, velocity: Double, decelerationRate: Double = 0.997) -> Double {
        // Same model as UIScrollView's deceleration: v * r / (1 - r) per millisecond.
        let perMs = velocity / 1000
        return value + perMs * decelerationRate / (1 - decelerationRate)
    }
}
