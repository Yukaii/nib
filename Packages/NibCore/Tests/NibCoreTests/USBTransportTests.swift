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
}
