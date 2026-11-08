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

  @Test func streamSkipsUnknownControlMessages() throws {
    let body = Array(#"{"type":"futureThing","x":1}"#.utf8)
    let length = UInt32(body.count)
    let unknown = [StreamFramer.controlType, UInt8(length), 0, 0, 0] + body
    var framer = StreamFramer()
    let bytes = StreamFramer.encode(.control(.ping)) + unknown + StreamFramer.encode(.control(.ping))
    #expect(try framer.append(bytes) == [.control(.ping), .control(.ping)])
    #expect(framer.bufferedByteCount == 0)
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

  private func usbmuxdPacket(_ plist: [String: Any], tag: UInt32) throws -> Data {
    let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    var packet = Data()
    let length = UInt32(UsbmuxPacket.headerLength + body.count)
    for value in [length, UInt32(1), UInt32(8), tag] {
      packet.append(UInt8(truncatingIfNeeded: value))
      packet.append(UInt8(truncatingIfNeeded: value >> 8))
      packet.append(UInt8(truncatingIfNeeded: value >> 16))
      packet.append(UInt8(truncatingIfNeeded: value >> 24))
    }
    packet.append(body)
    return packet
  }

  // Shapes captured from a real usbmuxd (macOS, iPad mini on USB).
  @Test func decodesRealUsbmuxdAttachedAndDetached() throws {
    let attached = try usbmuxdPacket(
      [
        "MessageType": "Attached", "DeviceID": 2660,
        "Properties": ["ConnectionType": "USB", "DeviceID": 2660],
      ], tag: 0)
    #expect(
      try UsbmuxPacket.decode(attached).message == .attached(deviceID: 2660, connectionType: "USB"))
    let detached = try usbmuxdPacket(["MessageType": "Detached", "DeviceID": 2660], tag: 0)
    #expect(try UsbmuxPacket.decode(detached).message == .detached(deviceID: 2660))
  }

  // usbmuxd sends Result and Attached back to back; the second read used to trap.
  @Test func framerDecodesConsecutivePacketsInOneBuffer() throws {
    var buffer = try usbmuxdPacket(["MessageType": "Result", "Number": 0], tag: 1)
    buffer.append(
      try usbmuxdPacket(
        ["MessageType": "Attached", "DeviceID": 3, "Properties": ["ConnectionType": "USB"]], tag: 0))
    var framer = UsbmuxConnectResultFramer()
    #expect(try framer.append(buffer)?.message == .result(code: 0))
    #expect(try framer.append(Data())?.message == .attached(deviceID: 3, connectionType: "USB"))
    #expect(try UsbmuxPacket.decode(buffer.dropFirst(0)).message == .result(code: 0))
  }

  @Test func requestsUseMessageTypeKey() throws {
    for request in [UsbmuxPacket.listenRequest(), UsbmuxPacket.connectRequest(deviceID: 7)] {
      let body = request.dropFirst(UsbmuxPacket.headerLength)
      let plist = try #require(
        PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
      #expect(plist["MessageType"] is String)
    }
  }

  @Test func connectResultFramerPreservesFollowingBytes() throws {
    let result = UsbmuxPacket(tag: 4, message: .result(code: 0))
    var packet = try usbmuxdPacket(["MessageType": "Result", "Number": 0], tag: 4)
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
    #expect(USBTransportArbitration.decide(current: .wifiSession, newcomer: .usb) == .replace)
    #expect(USBTransportArbitration.decide(current: .usbSession, newcomer: .usb) == .busy)
    #expect(USBTransportArbitration.decide(current: .none, newcomer: .usb) == .accept)
  }

  @Test func arbitrationCoversEveryConnectionState() {
    let states: [USBTransportState] = [
      .none, .wifiPending, .wifiPairingOnlyIdle, .wifiPairingActive, .wifiSession,
      .usbPending, .usbPairingOnly, .usbSession,
    ]
    for state in states {
      let wifi = USBTransportArbitration.decide(current: state, newcomer: .wifi)
      let usb = USBTransportArbitration.decide(current: state, newcomer: .usb)
      switch state {
      case .none:
        #expect(wifi == .accept)
        #expect(usb == .accept)
      case .wifiPending, .wifiPairingOnlyIdle:
        #expect(wifi == .replace)
        #expect(usb == .replace)
      case .wifiSession:
        #expect(wifi == .busy)
        #expect(usb == .replace)
      case .wifiPairingActive:
        #expect(wifi == .busy)
        #expect(usb == .busy)
      case .usbPending, .usbPairingOnly, .usbSession:
        #expect(wifi == .busy)
        #expect(usb == .busy)
      }
    }
  }

  @Test func wifiHellosStayBusyDuringUSBPairingOnly() throws {
    let hello = ControlMessage.Hello(
      appVersion: "1", deviceID: "device", deviceName: "iPad", surfaceWidth: 1,
      surfaceHeight: 1)
    let bytes = StreamFramer.encode(.control(.hello(hello)))
    var framer = StreamFramer()
    for _ in 0..<3 {
      #expect(try framer.append(bytes) == [.control(.hello(hello))])
      #expect(
        USBTransportArbitration.decide(current: .usbPairingOnly, newcomer: .wifi) == .busy)
    }
  }

  @Test func pairingChoosesUSBWhenBothTransportsAreLive() {
    #expect(USBPairingTransport.choose(usbHasLiveConnection: true) == .usb)
    #expect(USBPairingTransport.choose(usbHasLiveConnection: false) == .wifi)
  }

  @Test func wifiPausesForCableAndResumesOnceOnUnplug() {
    #expect(WiFiTransportDecision.transition(wifiPaused: false, usbConnected: true) == .pause)
    #expect(WiFiTransportDecision.transition(wifiPaused: true, usbConnected: false) == .resume)
    #expect(WiFiTransportDecision.transition(wifiPaused: false, usbConnected: false) == .unchanged)
    #expect(WiFiTransportDecision.transition(wifiPaused: true, usbConnected: true) == .unchanged)
  }

  @Test func hostRestartSchedulesOnlyOneWifiReconnect() {
    #expect(WiFiReconnectDecision.decide(paused: false, alreadyScheduled: false) == .schedule)
    #expect(WiFiReconnectDecision.decide(paused: false, alreadyScheduled: true) == .ignore)
    #expect(WiFiReconnectDecision.decide(paused: true, alreadyScheduled: false) == .ignore)
  }

  @Test func usbHeartbeatTimesOutAfterThreeSecondsWithoutTraffic() {
    #expect(!USBHeartbeatPolicy.isTimedOut(lastTraffic: 10, now: 12.99))
    #expect(USBHeartbeatPolicy.isTimedOut(lastTraffic: 10, now: 13))
    #expect(!USBHeartbeatPolicy.isTimedOut(lastTraffic: nil, now: 100))
  }
}

// Found on device: start(hello:) stopped the old listener and threw away the
// pairing driver configured just before, so USB could never begin pairing.
@Test @MainActor func usbPairingDriverSurvivesStop() {
  let usb = UsbLinkListener()
  usb.configurePairing(store: InMemoryPairingKeyStore(), hostID: "pending-host")
  #expect(usb.canPair)
  usb.stop()
  #expect(usb.canPair)
}

@Test @MainActor func wifiPairingDriverSurvivesStop() {
  let sender = PenLinkSender()
  sender.configurePairing(store: InMemoryPairingKeyStore(), hostID: "pending-host")
  #expect(sender.canPair)
  sender.stop()
  #expect(sender.canPair)
}
