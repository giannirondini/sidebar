import CoreGraphics
import Foundation

/// Pure decisions behind the space transition: whether a released
/// swipe switches, the rubber-band past the first and last space, and the spring
/// that settles the page. No AppKit, so it is unit-tested directly.
enum SpaceSwipe {
    enum Outcome: Equatable {
        /// Finger moved right: the space before the current one.
        case previous
        /// Finger moved left: the space after the current one.
        case next
        /// Snap back to the current space.
        case stay
    }

    /// What a release does. `translation` > 0 means the finger moved right.
    ///
    /// - A fast release (`flickVelocity`) in the drag's direction switches.
    /// - A fast release against the drag's direction stays (the user changed their mind).
    /// - Otherwise it switches only past `commitFraction` of the width.
    /// - It never switches to a space that doesn't exist.
    static func outcome(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat,
        canGoPrevious: Bool,
        canGoNext: Bool,
        commitFraction: CGFloat = ThemeConstants.SpaceTransition.commitFraction,
        flickVelocity: CGFloat = ThemeConstants.SpaceTransition.flickVelocity
    ) -> Outcome {
        guard translation != 0, width > 0 else { return .stay }
        let isFlick = abs(velocity) >= flickVelocity
        let switches: Bool
        if isFlick {
            switches = (velocity > 0) == (translation > 0)
        } else {
            switches = abs(translation) > commitFraction * width
        }
        guard switches else { return .stay }
        if translation > 0 {
            return canGoPrevious ? .previous : .stay
        }
        return canGoNext ? .next : .stay
    }

    /// Offset shown for a drag of `offset` points where there is no space to go to:
    /// it follows the finger less and less, never past `dimension`.
    static func rubberBand(
        _ offset: CGFloat,
        dimension: CGFloat,
        coefficient: CGFloat = ThemeConstants.SpaceTransition.rubberBandCoefficient
    ) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let magnitude = (1 - 1 / (abs(offset) * coefficient / dimension + 1)) * dimension
        return offset < 0 ? -magnitude : magnitude
    }

    /// A spring described by its response (period) and damping ratio, as
    /// `CASpringAnimation` parameters (mass 1).
    struct Spring: Equatable {
        var response: Double
        var dampingRatio: Double

        static let standard = Spring(
            response: ThemeConstants.SpaceTransition.springResponse,
            dampingRatio: ThemeConstants.SpaceTransition.springDampingRatio
        )

        /// Natural angular frequency ω (rad/s).
        var omega: Double { 2 * .pi / response }
        var stiffness: Double { omega * omega }
        var damping: Double { 2 * dampingRatio * omega }

        /// `CASpringAnimation.initialVelocity` (in units of the distance to travel
        /// per second) for a release at `velocity` pt/s with `remaining` points to go.
        ///
        /// A critically damped spring still overshoots when it starts faster than
        /// ω × remaining, which would show an empty strip past the incoming page;
        /// so the speed toward the target is capped there. Speed away from the
        /// target is kept (the page carries on briefly, then comes back).
        func initialVelocity(releaseVelocity velocity: CGFloat, remaining: CGFloat) -> Double {
            guard remaining != 0 else { return 0 }
            var speed = Double(velocity)
            let towardTarget = (velocity > 0) == (remaining > 0)
            if towardTarget {
                let cap = omega * Double(abs(remaining))
                speed = speed > 0 ? min(speed, cap) : max(speed, -cap)
            }
            return speed / Double(remaining)
        }

        /// Fraction of the travel done at `t` seconds (0 at the start, → 1), for a start
        /// at `initialVelocity` (travels per second, as above). Closed form, so other
        /// things (the Favorites' height) can follow the pages' spring exactly.
        func position(at t: Double, initialVelocity v0: Double) -> Double {
            guard t > 0 else { return 0 }
            let w = omega, z = dampingRatio
            if abs(z - 1) < 1e-9 {
                return 1 - (1 + (w - v0) * t) * exp(-w * t)
            }
            if z < 1 {
                let wd = w * (1 - z * z).squareRoot()
                return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w - v0) / wd * sin(wd * t))
            }
            let root = (z * z - 1).squareRoot()
            let r1 = -w * (z - root), r2 = -w * (z + root)
            let c1 = (-v0 - r2) / (r1 - r2)
            return 1 - (c1 * exp(r1 * t) + (1 - c1) * exp(r2 * t))
        }

        /// Seconds until the motion stays within `tolerance` points of the end, for a
        /// travel of `distance` points starting at `initialVelocity` (as above). The
        /// spring is visually done by then; `CASpringAnimation.settlingDuration` waits
        /// for it to stop entirely (0.5 s vs ~0.4 s for a 340-pt page), and only
        /// then does the transition land.
        func visualDuration(initialVelocity: Double, distance: Double, tolerance: Double) -> Double {
            let span = abs(distance)
            guard span > tolerance else { return 0 }
            // Simulate x'' = -k(x - 1) - c x' (x: fraction of the travel) and keep
            // the last moment the remaining distance is above tolerance.
            let step = 0.0005
            let horizon = 3.0
            var x = 0.0, v = initialVelocity, t = 0.0, last = 0.0
            while t < horizon {
                let a = -stiffness * (x - 1) - damping * v
                v += a * step
                x += v * step
                t += step
                if abs(1 - x) * span > tolerance { last = t }
            }
            return last
        }
    }
}

/// Release speed of a trackpad swipe, from the scroll deltas of its last moments.
/// Fed `(timestamp, deltaX)` per event; the `.ended` event (zero delta) only
/// supplies the end time, and momentum events afterwards are not fed at all.
struct SwipeVelocityEstimator {
    private struct Sample {
        let time: TimeInterval
        let deltaX: CGFloat
    }

    let window: TimeInterval
    private var samples: [Sample] = []

    init(window: TimeInterval = ThemeConstants.SpaceTransition.velocityWindow) {
        self.window = window
    }

    /// Starts a gesture at `time` (no movement yet).
    mutating func begin(at time: TimeInterval) {
        samples = [Sample(time: time, deltaX: 0)]
    }

    mutating func add(time: TimeInterval, deltaX: CGFloat) {
        samples.append(Sample(time: time, deltaX: deltaX))
        // Older samples can't matter once a newer one is a full window away.
        if let cutoff = samples.lastIndex(where: { $0.time < time - window }), cutoff > 0 {
            samples.removeFirst(cutoff)
        }
    }

    /// Points per second over the window ending at `endTime`. A finger that
    /// paused for a whole window before lifting has velocity 0.
    func velocity(at endTime: TimeInterval) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        let windowStart = endTime - window
        // Each sample's delta is the movement since the sample before it, so the
        // span starts at the last sample before the window (or the gesture start).
        let firstInside = samples.firstIndex(where: { $0.time >= windowStart }) ?? samples.count
        let baseIndex = max(0, firstInside - 1)
        let base = samples[baseIndex].time
        let distance = samples[(baseIndex + 1)...].reduce(CGFloat(0)) { $0 + $1.deltaX }
        let span = endTime - base
        guard span > 0, distance != 0 else { return 0 }
        return distance / CGFloat(span)
    }
}
