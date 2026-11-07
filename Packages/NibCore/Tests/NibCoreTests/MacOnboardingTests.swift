import Testing

@testable import NibCore

struct MacOnboardingTests {
  @Test func untrustedNeedsAccessibility() {
    #expect(
      MacOnboardingStep.resolve(trusted: false, needsRestart: false, connected: false, setupCompleted: false)
        == .accessibility)
  }

  @Test func permissionGrantedDuringRunNeedsRestart() {
    #expect(
      MacOnboardingStep.resolve(trusted: true, needsRestart: true, connected: false, setupCompleted: false)
        == .restart)
  }

  @Test func trustedAndDisconnectedNeedsConnect() {
    #expect(
      MacOnboardingStep.resolve(trusted: true, needsRestart: false, connected: false, setupCompleted: false)
        == .connect)
  }

  @Test func connectedNeedsPressureTest() {
    #expect(
      MacOnboardingStep.resolve(trusted: true, needsRestart: false, connected: true, setupCompleted: false)
        == .tryIt)
  }

  @Test func completedSetupDoesNotNeedWindow() {
    #expect(
      MacOnboardingStep.resolve(trusted: true, needsRestart: false, connected: true, setupCompleted: true)
        == .completed)
  }

  @Test func revokedAccessibilityOverridesCompletedSetup() {
    #expect(
      MacOnboardingStep.resolve(trusted: false, needsRestart: false, connected: true, setupCompleted: true)
        == .accessibility)
  }

  @Test func pendingRestartOverridesCompletedSetup() {
    #expect(
      MacOnboardingStep.resolve(trusted: true, needsRestart: true, connected: true, setupCompleted: true)
        == .restart)
  }
}
