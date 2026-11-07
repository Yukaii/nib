import Foundation
import NibCore
import Testing

struct USBTransportTests {
  @Test func listenHeaderUsesUsbmuxLittleEndianEnvelope() {
    let bytes = UsbmuxPacket.listenRequest(tag: 7)
    #expect(Array(bytes[4..<8]) == [1, 0, 0, 0])
    #expect(Array(bytes[8..<12]) == [8, 0, 0, 0])
    #expect(Array(bytes[12..<16]) == [7, 0, 0, 0])
  }

  @Test func connectPortIsNetworkOrderInsidePlist() throws {
    let request = UsbmuxPacket.connectRequest(deviceID: 42, port: 47811, tag: 2)
    let packet = try UsbmuxPacket.decode(request)
    #expect(packet == UsbmuxPacket(tag: 2, message: .connect(deviceID: 42, port: 47811)))
  }

  @Test func streamFramesDecodeOneByteAtATime() throws {
    let sample = PenSample(
      kind: .move, sequence: 3, timestamp: 9, x: 0.2, y: 0.3, pressure: 0.4, altitude: 1, azimuth: 2)
    let messages: [StreamFrame] = [.control(.ping), .sample(sample), .control(.probe(sentAtNs: 99))]
    let bytes = messages.flatMap(StreamFramer.encode)
    var framer = StreamFramer()
    var decoded: [StreamFrame] = []
    for byte in bytes { decoded += try framer.append([byte]) }
    #expect(decoded == messages)
  }

  @Test func streamRejectsUnknownAndWaitsForTruncatedSample() throws {
    var framer = StreamFramer()
    #expect(throws: StreamFramer.Error.unknownType(0x7f)) { try framer.append([0x7f]) }
    var truncated = StreamFramer()
    #expect(try truncated.append([StreamFramer.sampleType]).isEmpty)
    #expect(truncated.bufferedByteCount == 1)
  }

  @Test func onlyIPv4AndIPv6LoopbackAreAllowed() {
    #expect(USBPeerPolicy.allowsLoopbackPeer("127.0.0.1"))
    #expect(USBPeerPolicy.allowsLoopbackPeer("::1"))
    #expect(USBPeerPolicy.allowsLoopbackPeer("::1%lo0"))
    #expect(!USBPeerPolicy.allowsLoopbackPeer("192.168.1.2"))
    #expect(!USBPeerPolicy.allowsLoopbackPeer("localhost"))
  }

  @Test func connectResultFramerPreservesFollowingBytes() throws {
    let result = UsbmuxPacket(tag: 4, message: .result(code: 0))
    let body = try PropertyListSerialization.data(
      fromPropertyList: ["Message": "Result", "Number": 0], format: .xml, options: 0)
    var packet = Data()
    let length = UInt32(UsbmuxPacket.headerLength + body.count)
    for value in [length, UInt32(1), UInt32(8), UInt32(4)] {
      packet.append(UInt8(truncatingIfNeeded: value))
      packet.append(UInt8(truncatingIfNeeded: value >> 8))
      packet.append(UInt8(truncatingIfNeeded: value >> 16))
      packet.append(UInt8(truncatingIfNeeded: value >> 24))
    }
    packet.append(body)
    packet.append(contentsOf: [0x01, 0x02, 0x03])
    var framer = UsbmuxConnectResultFramer()
    #expect(try framer.append(packet) == result)
    #expect(framer.bufferedByteCount == 3)
  }

  @Test func busySenderRejectionRetries() {
    #expect(PenLinkRejectionPolicy.decision(reason: "busy") == .retryLater)
    #expect(PenLinkRejectionPolicy.decision(reason: "rejected") == .final)
  }

  @Test func usbReplacesWifiButUsbIsExclusive() {
    #expect(USBTransportArbitration.decide(current: .wifi, newcomer: .usb) == .replace)
    #expect(USBTransportArbitration.decide(current: .usb, newcomer: .usb) == .busy)
    #expect(USBTransportArbitration.decide(current: .none, newcomer: .usb) == .accept)
  }

  @Test func usbHeartbeatTimesOutAfterThreeSecondsWithoutTraffic() {
    #expect(!USBHeartbeatPolicy.isTimedOut(lastTraffic: 10, now: 12.99))
    #expect(USBHeartbeatPolicy.isTimedOut(lastTraffic: 10, now: 13))
    #expect(!USBHeartbeatPolicy.isTimedOut(lastTraffic: nil, now: 100))
  }
}
