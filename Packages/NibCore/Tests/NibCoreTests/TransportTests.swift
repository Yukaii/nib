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
}
