import CoreGraphics
import Foundation
import Testing
@testable import SidebArcCore

@Suite struct SpaceSwipeTests {
    private let width: CGFloat = 320

    // MARK: - Outcome

    @Test func slowDragSwitchesOnlyPastTheCommitFraction() {
        let short = SpaceSwipe.outcome(translation: -90, velocity: -50, width: width, canGoPrevious: true, canGoNext: true)
        let far = SpaceSwipe.outcome(translation: -100, velocity: -50, width: width, canGoPrevious: true, canGoNext: true)
        #expect(short == .stay)   // 90 < 0.3 × 320 = 96
        #expect(far == .next)
        #expect(SpaceSwipe.outcome(translation: 120, velocity: 0, width: width, canGoPrevious: true, canGoNext: true) == .previous)
    }

    @Test func flickInTheDragDirectionSwitchesEvenWhenShort() {
        #expect(SpaceSwipe.outcome(translation: 30, velocity: 900, width: width, canGoPrevious: true, canGoNext: true) == .previous)
        #expect(SpaceSwipe.outcome(translation: -30, velocity: -900, width: width, canGoPrevious: true, canGoNext: true) == .next)
    }

    @Test func flickBackAgainstTheDragStays() {
        // Dragged well past the threshold, then flicked back: the user changed their mind.
        #expect(SpaceSwipe.outcome(translation: 180, velocity: -1500, width: width, canGoPrevious: true, canGoNext: true) == .stay)
    }

    @Test func neverSwitchesPastTheEnds() {
        #expect(SpaceSwipe.outcome(translation: 250, velocity: 2000, width: width, canGoPrevious: false, canGoNext: true) == .stay)
        #expect(SpaceSwipe.outcome(translation: -250, velocity: -2000, width: width, canGoPrevious: true, canGoNext: false) == .stay)
        #expect(SpaceSwipe.outcome(translation: 0, velocity: 2000, width: width, canGoPrevious: true, canGoNext: true) == .stay)
    }

    // MARK: - Rubber band

    @Test func rubberBandFollowsLessAndNeverExceedsTheWidth() {
        let small = SpaceSwipe.rubberBand(20, dimension: width)
        let large = SpaceSwipe.rubberBand(2000, dimension: width)
        #expect(small > 0 && small < 20)
        #expect(large < width)
        #expect(SpaceSwipe.rubberBand(-20, dimension: width) == -small)
        #expect(SpaceSwipe.rubberBand(0, dimension: width) == 0)
        // Monotonic: more drag, more offset.
        #expect(SpaceSwipe.rubberBand(100, dimension: width) < SpaceSwipe.rubberBand(200, dimension: width))
    }

    // MARK: - Spring

    @Test func springParametersFromResponse() {
        let spring = SpaceSwipe.Spring(response: 0.5, dampingRatio: 1)
        #expect(abs(spring.omega - 4 * .pi) < 1e-9)
        #expect(abs(spring.stiffness - spring.omega * spring.omega) < 1e-9)
        #expect(abs(spring.damping - 2 * spring.omega) < 1e-9)
    }

    @Test func releaseSpeedTowardTheTargetIsCappedSoItCannotOvershoot() {
        let spring = SpaceSwipe.Spring.standard
        let remaining: CGFloat = 200
        let cap = spring.omega * 200
        // A very fast flick: capped at ω × remaining (in distance units: ω).
        #expect(abs(spring.initialVelocity(releaseVelocity: 10_000, remaining: remaining) - cap / 200) < 1e-9)
        // A slow one is kept.
        #expect(abs(spring.initialVelocity(releaseVelocity: 100, remaining: remaining) - 0.5) < 1e-9)
        // Toward a negative target: same cap, sign kept.
        #expect(abs(spring.initialVelocity(releaseVelocity: -10_000, remaining: -remaining) - cap / 200) < 1e-9)
        // Away from the target: not capped (negative in distance units).
        #expect(spring.initialVelocity(releaseVelocity: -10_000, remaining: remaining) == -50)
        #expect(spring.initialVelocity(releaseVelocity: 500, remaining: 0) == 0)
    }

    // MARK: - Velocity estimator

    private func estimator(steps: [(dt: TimeInterval, dx: CGFloat)]) -> (SwipeVelocityEstimator, TimeInterval) {
        var estimator = SwipeVelocityEstimator(window: 0.08)
        var time: TimeInterval = 100
        estimator.begin(at: time)
        for step in steps {
            time += step.dt
            estimator.add(time: time, deltaX: step.dx)
        }
        return (estimator, time)
    }

    @Test func flickRightIsFast() {
        let (e, last) = estimator(steps: Array(repeating: (0.01, 30), count: 10))
        let v = e.velocity(at: last + 0.005)
        #expect(v > 2_000)   // ≈ 30 pt per 10 ms = 3000 pt/s
        #expect(v <= 3_000)
    }

    @Test func slowDragIsSlow() {
        let (e, last) = estimator(steps: Array(repeating: (0.01, 2), count: 30))
        let v = e.velocity(at: last + 0.005)
        #expect(v > 100 && v < 250)   // ≈ 200 pt/s
    }

    @Test func dragRightThenFlickBackLeftIsNegative() {
        let (e, last) = estimator(steps: Array(repeating: (0.01, 30), count: 10) + Array(repeating: (0.01, -30), count: 6))
        let v = e.velocity(at: last + 0.005)
        // The window still holds a little of the rightward drag; it is clearly a flick back.
        #expect(v < -1_000)
        // Net translation is +120 (right), so the release stays on the current space.
        #expect(SpaceSwipe.outcome(translation: 120, velocity: v, width: 320, canGoPrevious: true, canGoNext: true) == .stay)
    }

    @Test func pauseBeforeLiftingIsZero() {
        let (e, last) = estimator(steps: Array(repeating: (0.01, 30), count: 10))
        #expect(e.velocity(at: last + 0.2) == 0)
    }

    @Test func noMovementIsZero() {
        var e = SwipeVelocityEstimator(window: 0.08)
        e.begin(at: 5)
        #expect(e.velocity(at: 5.05) == 0)
        #expect(SwipeVelocityEstimator().velocity(at: 1) == 0)
    }

    @Test func singleSampleUsesTheTimeSinceTheGestureBegan() {
        let (e, last) = estimator(steps: [(0.02, 10)])
        #expect(abs(e.velocity(at: last) - 500) < 1)   // 10 pt in 20 ms
    }
}

/// The spring lands once it's visually done (Favorites of another profile and the
/// live page come sooner), not when CASpringAnimation considers it stopped.
@Suite struct SpringLandingTests {
    private let spring = SpaceSwipe.Spring.standard

    /// Remaining distance (points) of a critically damped spring, closed form.
    private func remaining(at t: Double, distance: Double, v0: Double) -> Double {
        let w = spring.omega
        return abs(distance * (1 + (w - v0) * t) * exp(-w * t))
    }

    @Test func aPageLandsBeforeTheSpringStopsAndWithinTolerance() {
        let tolerance = ThemeConstants.SpaceTransition.landingTolerance
        for v0 in [0.0, 2.0, 5.0] {
            let t = spring.visualDuration(initialVelocity: v0, distance: 340, tolerance: tolerance)
            #expect(t > 0.25 && t < 0.5, "v0 \(v0): \(t)")
            #expect(remaining(at: t + 0.001, distance: 340, v0: v0) < tolerance)
            #expect(remaining(at: t - 0.02, distance: 340, v0: v0) >= tolerance)
        }
    }

    /// The Favorites' height follows `position(at:)`; it must be the same curve the
    /// pages run (checked against the simulation behind `visualDuration`).
    @Test func positionIsTheSpringCurve() {
        for v0 in [0.0, 3.0] {
            #expect(spring.position(at: 0, initialVelocity: v0) == 0)
            let t = spring.visualDuration(initialVelocity: v0, distance: 340, tolerance: 0.5)
            #expect(abs(1 - spring.position(at: t + 0.001, initialVelocity: v0)) * 340 < 0.5)
            #expect(abs(1 - spring.position(at: t - 0.02, initialVelocity: v0)) * 340 >= 0.5)
            var previous = 0.0
            for step in 1...100 {      // critically damped from rest or toward the target: never goes back
                let x = spring.position(at: Double(step) * 0.005, initialVelocity: v0)
                #expect(x >= previous)
                previous = x
            }
        }
        // Other damping ratios use their own closed forms; all end at 1.
        for ratio in [0.7, 1.5] {
            let other = SpaceSwipe.Spring(response: 0.32, dampingRatio: ratio)
            #expect(abs(other.position(at: 3, initialVelocity: 0) - 1) < 0.001)
        }
    }

    @Test func noTravelNeedsNoTime() {
        #expect(spring.visualDuration(initialVelocity: 0, distance: 0.2, tolerance: 0.5) == 0)
    }

    @Test func aLooserToleranceLandsSooner() {
        let tight = spring.visualDuration(initialVelocity: 0, distance: 340, tolerance: 0.5)
        let loose = spring.visualDuration(initialVelocity: 0, distance: 340, tolerance: 5)
        #expect(loose < tight)
    }
}
