import Foundation

/// Frames carried by the reliable usbmux stream.
public enum StreamFrame: Sendable, Equatable {
  case control(ControlMessage)
  case sample(PenSample)
}

/// Incremental decoder for the one-byte type tagged USB stream.
public struct StreamFramer: Sendable {
  public typealias Frame = StreamFrame
  public enum Error: Swift.Error, Equatable {
    case unknownType(UInt8)
    case invalidControl
    case invalidSample
  }

  public static let controlType: UInt8 = 0x01
  public static let sampleType: UInt8 = 0x02
  private var bytes: [UInt8] = []

  public init() {}

  public mutating func append(_ chunk: [UInt8]) throws -> [StreamFrame] {
    bytes.append(contentsOf: chunk)
    var frames: [StreamFrame] = []
    while !bytes.isEmpty {
      switch bytes[0] {
      case Self.sampleType:
        guard bytes.count >= 1 + PenSample.byteCount else { return frames }
        let payload = bytes[1..<(1 + PenSample.byteCount)]
        guard let sample = try? PenSample(decoding: payload) else { throw Error.invalidSample }
        frames.append(.sample(sample))
        bytes.removeFirst(1 + PenSample.byteCount)
      case Self.controlType:
        guard bytes.count >= 5 else { return frames }
        let length =
          UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16
          | UInt32(bytes[4]) << 24
        guard length <= ControlFramer.maximumMessageSize, length >= 2 else {
          throw Error.invalidControl
        }
        let total = 1 + 4 + Int(length)
        guard bytes.count >= total else { return frames }
        var control = ControlFramer()
        do {
          for message in try control.append(Array(bytes[1..<total])) {
            frames.append(.control(message))
          }
        } catch {
          throw Error.invalidControl
        }
        bytes.removeFirst(total)
      default:
        throw Error.unknownType(bytes[0])
      }
    }
    return frames
  }

  public mutating func feed(_ chunk: [UInt8]) throws -> [StreamFrame] { try append(chunk) }
  public var bufferedByteCount: Int { bytes.count }

  public static func encode(_ frame: StreamFrame) -> [UInt8] {
    switch frame {
    case .control(let message): return [controlType] + ControlFramer().encode(message)
    case .sample(let sample): return [sampleType] + sample.encode()
    }
  }
}

public enum USBPeerPolicy {
  /// usbmuxd presents itself as loopback to the iPad. No DNS resolution is
  /// performed here, which keeps LAN host names from becoming an allowlist.
  public static func allowsLoopbackPeer(_ host: String) -> Bool {
    let normalized = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
    return normalized == "127.0.0.1" || normalized == "::1"
  }
}

public enum USBTransport: Sendable, Equatable {
  case none, wifi, usb
}

public enum USBTransportDecision: Sendable, Equatable {
  case accept, replace, busy
}

public enum USBTransportState: Sendable, Equatable {
  case none
  case wifiPending
  case wifiPairingOnlyIdle
  case wifiPairingActive
  case wifiSession
  case usbPending
  case usbPairingOnly
  case usbSession
}

/// USB is preferred in every state, but an active pairing machine owns its
/// connection until it finishes or times out.
public enum USBTransportArbitration {
  public static func decide(
    current: USBTransportState, newcomer: USBTransport
  ) -> USBTransportDecision {
    switch (current, newcomer) {
    case (.usbPending, _), (.usbPairingOnly, _), (.usbSession, _):
      return .busy
    case (.wifiPairingActive, _):
      return .busy
    case (.wifiPending, .usb), (.wifiPairingOnlyIdle, .usb), (.wifiSession, .usb):
      return .replace
    case (.wifiPending, .wifi), (.wifiPairingOnlyIdle, .wifi), (.wifiSession, .wifi):
      return .replace
    default:
      return .accept
    }
  }
}

public enum USBHeartbeatPolicy {
  public static let timeout: TimeInterval = 3

  public static func isTimedOut(lastTraffic: TimeInterval?, now: TimeInterval) -> Bool {
    guard let lastTraffic else { return false }
    return now - lastTraffic >= timeout
  }
}
