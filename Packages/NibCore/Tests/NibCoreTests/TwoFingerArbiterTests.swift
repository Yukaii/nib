import NibCore
import Testing

struct TwoFingerArbiterTests {
  @Test func staysUndecidedBelowAllThresholds() {
    var arbiter = TwoFingerArbiter()
    arbiter.add(dx: 5, dy: 5, scale: 1.02, rotationDegrees: 2)
    #expect(arbiter.mode == .undecided)
  }

  @Test func slideLocksToPanAndIgnoresSmallTwist() {
    var arbiter = TwoFingerArbiter()
    arbiter.add(dx: 20, rotationDegrees: 3)
    #expect(arbiter.mode == .pan)
    arbiter.add(dx: 40, rotationDegrees: 10)
    #expect(arbiter.mode == .pan)
  }

  @Test func twistWithCentroidDriftLocksToTransform() {
    // A real twist drifts the centroid; rotation dominates relative to its threshold.
    var arbiter = TwoFingerArbiter()
    arbiter.add(dx: 8, dy: 4, rotationDegrees: 7)
    #expect(arbiter.mode == .transform)
    #expect(arbiter.rotateEngaged)
    #expect(!arbiter.zoomEngaged)
    arbiter.add(dx: 100)
    #expect(arbiter.mode == .transform)
  }

  @Test func deliberateTwistEscalatesPanToTransform() {
    var arbiter = TwoFingerArbiter()
    arbiter.add(dx: 30)
    #expect(arbiter.mode == .pan)
    arbiter.add(rotationDegrees: 21)
    #expect(arbiter.mode == .transform)
    #expect(arbiter.rotateEngaged)
    #expect(arbiter.rotationDegrees == 21)
  }

  @Test func pinchEngagesZoomAndLaterRotation() {
    var arbiter = TwoFingerArbiter()
    arbiter.add(scale: 1.1)
    #expect(arbiter.mode == .transform && arbiter.zoomEngaged && !arbiter.rotateEngaged)
    arbiter.add(rotationDegrees: 7)
    #expect(arbiter.rotateEngaged)
  }

  @Test func disabledComponentsNeverDecide() {
    var arbiter = TwoFingerArbiter(rotateEnabled: false)
    arbiter.add(rotationDegrees: 90)
    #expect(arbiter.mode == .undecided)
    arbiter.add(dx: 20)
    #expect(arbiter.mode == .pan)
    arbiter.add(rotationDegrees: 90)
    #expect(arbiter.mode == .pan)
  }

  @Test func resetKeepsConfiguration() {
    var arbiter = TwoFingerArbiter(zoomEnabled: false)
    arbiter.add(dx: 30)
    arbiter.reset()
    #expect(arbiter.mode == .undecided && arbiter.translationX == 0 && !arbiter.zoomEnabled)
  }
}
