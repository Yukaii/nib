import Testing

@testable import NibCore

struct PadOnboardingTests {
  @Test func duplicateBonjourNamesKeepFirstResult() {
    #expect(
      MacSelectionPolicy.deduplicatedNames(["Studio", "Studio", "Travel"])
        == ["Studio", "Travel"])
  }
  @Test func rememberedMacWinsWhenPresent() {
    #expect(
      MacSelectionPolicy.choose(remembered: "Studio", results: ["Living room", "Studio"])
        == .remembered("Studio"))
  }

  @Test func oneMacIsSelectedAutomatically() {
    #expect(MacSelectionPolicy.choose(remembered: nil, results: ["Studio"]) == .single("Studio"))
  }

  @Test func severalMacsNeedAnExplicitChoice() {
    #expect(MacSelectionPolicy.choose(remembered: nil, results: ["Studio", "Living room"]) == .ask)
  }

  @Test func browseChangesDoNotReplaceLiveConnection() {
    #expect(MacSelectionPolicy.shouldPreserveLiveConnection(hasConnection: true, choice: .ask))
    #expect(!MacSelectionPolicy.shouldPreserveLiveConnection(hasConnection: false, choice: .ask))
  }

  @Test func missingRememberedMacNeedsAnExplicitChoice() {
    #expect(MacSelectionPolicy.choose(remembered: "Studio", results: ["Living room", "Travel Mac"]) == .ask)
  }

  @Test func pressureNeedsEnoughSamples() {
    #expect(PressureCheckClassifier.classify([0, 0, 0]) == .notEnoughData)
  }

  @Test func zeroAndConstantForceMeanNoPressure() {
    let zero = Array(repeating: Float(0), count: PressureCheckClassifier.minimumSamples)
    let constant = Array(repeating: Float(1), count: PressureCheckClassifier.minimumSamples)
    #expect(PressureCheckClassifier.classify(zero) == .noPressure)
    #expect(PressureCheckClassifier.classify(constant) == .noPressure)
  }

  @Test func pressureRampPasses() {
    let ramp = (0..<PressureCheckClassifier.minimumSamples).map {
      Float($0) / Float(PressureCheckClassifier.minimumSamples - 1)
    }
    #expect(PressureCheckClassifier.classify(ramp) == .ok)
  }
}
