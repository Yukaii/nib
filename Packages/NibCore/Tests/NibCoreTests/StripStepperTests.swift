import NibCore
import Testing

struct StripStepperTests {
  @Test func wholeStepsKeepRemainder() {
    var stepper = StripStepper(step: 24)
    #expect(stepper.add(50) == 2)
    #expect(stepper.remainder == 2)
  }

  @Test func directionChangeDropsOldPartialDistance() {
    var stepper = StripStepper(step: 24)
    #expect(stepper.add(20) == 0)
    #expect(stepper.add(-24) == -1)
    #expect(stepper.remainder == 0)
  }

  @Test func endResetsAndInvalidInputIsIgnored() {
    var stepper = StripStepper(step: 24)
    #expect(stepper.add(12) == 0)
    #expect(stepper.add(.nan) == 0)
    #expect(stepper.add(.infinity) == 0)
    stepper.end()
    #expect(stepper.remainder == 0)
    #expect(stepper.add(-24) == -1)
  }
}
