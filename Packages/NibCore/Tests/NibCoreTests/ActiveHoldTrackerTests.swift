import Foundation
import NibCore
import Testing

struct ActiveHoldTrackerTests {
  @Test func releasesOnlyActiveHoldsAndClearsThem() {
    let first = UUID()
    let second = UUID()
    let a = Gesture.KeyChord(keyCode: 49)
    let b = Gesture.KeyChord(modifiers: [.option])
    var tracker = ActiveHoldTracker()
    tracker.begin(id: first, chord: a)
    tracker.begin(id: second, chord: b)
    #expect(tracker.end(id: first) == .key(a, action: .up))
    #expect(tracker.releaseAll() == [.key(b, action: .up)])
    #expect(tracker.releaseAll().isEmpty)
  }
}
