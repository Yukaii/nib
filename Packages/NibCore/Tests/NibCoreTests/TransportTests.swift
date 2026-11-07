import Foundation
import NibCore
import Testing

struct TransportTests {
  private let hello = ControlMessage.hello(
    .init(appVersion: "0.1.0", deviceName: "Pad", surfaceWidth: 1024, surfaceHeight: 768))

  @Test func controlMessagesRoundTrip() throws {
    let messages: [ControlMessage] = [
      hello, .helloAck(.init(accepted: true, udpPort: 1234, displayWidth: 1920, displayHeight: 1080)),
      .geometry(.init(surfaceWidth: 768, surfaceHeight: 1024)), .ping,
    ]
    for message in messages {
      var framer = ControlFramer()
      let bytes = framer.encode(message)
      #expect(try framer.append(bytes) == [message])
    }
  }

  @Test func controlChunksAndPingGolden() throws {
    let framer = ControlFramer()
    let encoded = framer.encode(.ping)
    #expect(encoded == [15, 0, 0, 0, 123, 34, 116, 121, 112, 101, 34, 58, 34, 112, 105, 110, 103, 34, 125])
    let messages: [ControlMessage] = [hello, .geometry(.init(surfaceWidth: 1, surfaceHeight: 2)), .ping]
    let bytes = messages.flatMap(framer.encode)
    var decoder = ControlFramer()
    var decoded: [ControlMessage] = []
    for byte in bytes { decoded += try decoder.append([byte]) }
    #expect(decoded == messages)
  }

  @Test func oversizedControlMessageThrows() {
    var framer = ControlFramer()
    let bytes: [UInt8] = [1, 0, 1, 0]
    #expect(throws: ControlFramer.Error.oversized(65_537)) { try framer.append(bytes) }
  }

  @Test func sequenceOrderingAndWrap() {
    var sequencer = SampleSequencer()
    func sample(_ sequence: UInt32) -> PenSample {
      PenSample(
        kind: .move, sequence: sequence, timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0)
    }
    var accepted = sequencer.accept(sample(10))
    #expect(accepted)
    accepted = sequencer.accept(sample(10))
    #expect(!accepted)
    accepted = sequencer.accept(sample(9))
    #expect(!accepted)
    accepted = sequencer.accept(sample(11))
    #expect(accepted)
    sequencer.reset()
    accepted = sequencer.accept(sample(UInt32.max))
    #expect(accepted)
    accepted = sequencer.accept(sample(0))
    #expect(accepted)
    accepted = sequencer.accept(sample(UInt32.max))
    #expect(!accepted)
  }

  @Test func sequenceHalfRangeIsNotNewer() {
    var sequencer = SampleSequencer()
    func sample(_ sequence: UInt32) -> PenSample {
      PenSample(
        kind: .move, sequence: sequence, timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0)
    }
    var accepted = sequencer.accept(sample(0))
    #expect(accepted)
    accepted = sequencer.accept(sample(0x8000_0000))
    #expect(!accepted)
    accepted = sequencer.accept(sample(0x7fff_ffff))
    #expect(accepted)
  }

  @Test func receiverSessionPolicy() {
    var session = ReceiverSession()
    #expect(
      session.hello(protocolVersion: PenSample.version, busy: false, acceptResult: true, now: 0) == .accepted)
    session.setRemoteHost("ipad")
    var accepted = session.acceptsUDP(from: "other", sequence: 1)
    #expect(!accepted)
    accepted = session.acceptsUDP(from: "ipad", sequence: 1)
    #expect(accepted)
    var expired = session.timeoutIfNeeded(at: 2.9)
    #expect(!expired)
    expired = session.timeoutIfNeeded(at: 3.0)
    #expect(expired)
    expired = session.timeoutIfNeeded(at: 4.0)
    #expect(!expired)
    session.disconnect()
    accepted = session.acceptsUDP(from: "ipad", sequence: 2)
    #expect(!accepted)
  }

  @Test func receiverSessionRejectsVersionAndBusy() {
    var version = ReceiverSession()
    #expect(
      version.hello(protocolVersion: PenSample.version &+ 1, busy: false, acceptResult: true, now: 0)
        == .rejected("Update the iPad app to the current version."))
    #expect(
      version.hello(protocolVersion: PenSample.version, busy: false, acceptResult: false, now: 0)
        == .rejected("rejected"))
    #expect(
      version.hello(protocolVersion: PenSample.version, busy: true, acceptResult: true, now: 0)
        == .rejected("busy"))
  }

  @Test func probesRoundTripThroughFramer() throws {
    for message in [ControlMessage.probe(sentAtNs: 123), .probeReply(sentAtNs: 456)] {
      var framer = ControlFramer()
      #expect(try framer.append(framer.encode(message)) == [message])
    }
  }
}

extension TransportTests {
  @Test func gestureControlMessagesRoundTrip() throws {
    let gestures: [Gesture] = [
      .scroll(dx: 1.25, dy: -2.5, phase: .began),
      .scroll(dx: -3, dy: 4, phase: .changed),
      .scroll(dx: 0, dy: 0, phase: .ended),
      .scroll(dx: 0, dy: 0, phase: .cancelled),
      .zoom(scaleDelta: 1.2, phase: .changed, modifier: .primary),
      .zoom(scaleDelta: 0.8, phase: .ended, modifier: .alt),
      .zoom(scaleDelta: 1, phase: .cancelled, modifier: .control),
      .undo, .redo,
      .key(.init(key: "KeyZ", modifiers: [.primary, .shift]), action: .tap),
    ]
    for gesture in gestures {
      let message = ControlMessage.gesture(gesture)
      var framer = ControlFramer()
      #expect(try framer.append(framer.encode(message)) == [message])
    }
  }

  @Test func frontAppRoundTripsThroughControlAndUSBFramers() throws {
    let message = ControlMessage.frontApp(.init(bundleID: "org.kde.krita", name: "Krita"))
    var control = ControlFramer()
    #expect(try control.append(control.encode(message)) == [message])
    var stream = StreamFramer()
    #expect(try stream.append(StreamFramer.encode(.control(message))) == [.control(message)])
  }

  @Test func oldZoomJSONDefaultsToModifierScrollAndRotateRoundTrips() throws {
    let old = #"{"type":"zoom","scaleDelta":1.1,"phase":"changed","modifier":"command"}"#
    let decoded = try JSONDecoder().decode(Gesture.self, from: Data(old.utf8))
    #expect(decoded == .zoom(scaleDelta: 1.1, phase: .changed, modifier: .primary))
    let rotate = Gesture.rotate(degreesDelta: 12, phase: .changed)
    var framer = ControlFramer()
    #expect(try framer.append(framer.encode(.gesture(rotate))) == [.gesture(rotate)])
  }

  @Test func palmRejectionCoversContactGracePeriod() {
    var policy = GesturePalmRejection()
    policy.pencilBegan()
    #expect(policy.suppresses(at: 0))
    policy.pencilEnded(at: 10)
    #expect(policy.suppresses(at: 10.299))
    #expect(!policy.suppresses(at: 10.3))
  }
}

@Test func keyChordV2RoundTripsNeutralAndModifierOnlyChords() throws {
  let chords = [
    Gesture.KeyChord(key: "KeyZ", modifiers: [.primary, .shift]),
    Gesture.KeyChord(modifiers: [.primary, .control, .alt, .shift, .meta]),
  ]
  for chord in chords {
    let data = try JSONEncoder().encode(chord)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("keyCode") && !json.contains("command") && !json.contains("option"))
    #expect(try JSONDecoder().decode(Gesture.KeyChord.self, from: data) == chord)
  }
}

@Test func v1KeyChordMigratesToNeutralWireShape() throws {
  let old = #"{"keyCode":6,"modifiers":["command","shift"]}"#
  let chord = try JSONDecoder().decode(Gesture.KeyChord.self, from: Data(old.utf8))
  #expect(chord == .init(key: "KeyZ", modifiers: [.primary, .shift]))
  let encoded = String(decoding: try JSONEncoder().encode(chord), as: UTF8.self)
  #expect(encoded.contains("KeyZ") && !encoded.contains("keyCode") && !encoded.contains("command"))
}
