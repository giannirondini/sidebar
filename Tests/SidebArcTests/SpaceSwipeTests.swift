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
