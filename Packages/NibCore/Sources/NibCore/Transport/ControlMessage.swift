import Foundation

public enum ProtocolVersion {
  public static let control: UInt8 = 2
}

/// Reliable control-channel messages exchanged before and alongside the UDP sample stream.
public enum ControlMessage: Codable, Equatable, Sendable {
  public typealias ProtocolVersion = NibCore.ProtocolVersion

  public enum Capability {
    public static let tilt = "tilt"
    public static let hover = "hover"
    public static let eraser = "eraser"
    public static let keys = "keys"
    public static let scroll = "scroll"
    public static let zoomModifierScroll = "zoomModifierScroll"
    public static let zoomNative = "zoomNative"
    public static let rotateNative = "rotateNative"
    public static let undoRedo = "undoRedo"
    public static let frontApp = "frontApp"
  }

  public struct HostInfo: Codable, Equatable, Sendable {
    public var platform: HostPlatform
    public var name: String
    public var appVersion: String
    public var capabilities: [String]

    public init(platform: HostPlatform, name: String, appVersion: String, capabilities: [String]) {
      self.platform = platform
      self.name = name
      self.appVersion = appVersion
      self.capabilities = capabilities
    }
  }

  public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: UInt8
    public var appVersion: String
    public var deviceID: String
    public var deviceName: String
    public var surfaceWidth: Double
    public var surfaceHeight: Double
    /// Fresh base64-encoded nonce and HMAC proof used after pairing.
    public var nonce: String?
    public var proof: String?

    public init(
      protocolVersion: UInt8 = ProtocolVersion.control, appVersion: String, deviceID: String = "",
      deviceName: String,
      surfaceWidth: Double,
      surfaceHeight: Double,
      nonce: String? = nil,
      proof: String? = nil
    ) {
      self.protocolVersion = protocolVersion
      self.appVersion = appVersion
      self.deviceID = deviceID
      self.deviceName = deviceName
      self.surfaceWidth = surfaceWidth
      self.surfaceHeight = surfaceHeight
      self.nonce = nonce
      self.proof = proof
    }

    private enum CodingKeys: String, CodingKey {
      case protocolVersion, appVersion, deviceID, deviceName, surfaceWidth, surfaceHeight, nonce, proof
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      protocolVersion = try values.decode(UInt8.self, forKey: .protocolVersion)
      appVersion = try values.decode(String.self, forKey: .appVersion)
      deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
      deviceName = try values.decode(String.self, forKey: .deviceName)
      surfaceWidth = try values.decode(Double.self, forKey: .surfaceWidth)
      surfaceHeight = try values.decode(Double.self, forKey: .surfaceHeight)
      nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
      proof = try values.decodeIfPresent(String.self, forKey: .proof)
    }
  }

  public struct HelloAck: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var reason: String?
    public var udpPort: UInt16
    public var displayWidth: Double
    public var displayHeight: Double
    public var host: HostInfo?
    public var nonce: String?
    public var proof: String?
    /// True when an unpaired iPad may pair on this same connection. The
    /// connection stays open in a pairing-only state; only hello, pairRequest,
    /// pairReveal, pairResult and ping are processed until pairing completes.
    public var pairingRequired: Bool?

    public init(
      accepted: Bool, reason: String? = nil, udpPort: UInt16 = 0, displayWidth: Double = 0,
      displayHeight: Double = 0, host: HostInfo? = nil, nonce: String? = nil, proof: String? = nil,
      pairingRequired: Bool? = nil
    ) {
      self.accepted = accepted
      self.reason = reason
      self.udpPort = udpPort
      self.displayWidth = displayWidth
      self.displayHeight = displayHeight
      self.host = host
      self.nonce = nonce
      self.proof = proof
      self.pairingRequired = pairingRequired
    }

    private enum CodingKeys: String, CodingKey {
      case accepted, reason, udpPort, displayWidth, displayHeight, host, nonce, proof, pairingRequired
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      accepted = try values.decode(Bool.self, forKey: .accepted)
      reason = try values.decodeIfPresent(String.self, forKey: .reason)
      udpPort = try values.decodeIfPresent(UInt16.self, forKey: .udpPort) ?? 0
      displayWidth = try values.decodeIfPresent(Double.self, forKey: .displayWidth) ?? 0
      displayHeight = try values.decodeIfPresent(Double.self, forKey: .displayHeight) ?? 0
      host = try values.decodeIfPresent(HostInfo.self, forKey: .host)
      nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
      proof = try values.decodeIfPresent(String.self, forKey: .proof)
      pairingRequired = try values.decodeIfPresent(Bool.self, forKey: .pairingRequired)
    }
  }

  public struct PairRequest: Codable, Equatable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var publicKey: String
    public var commitment: String
    public init(deviceID: String, deviceName: String, publicKey: String, commitment: String) {
      self.deviceID = deviceID
      self.deviceName = deviceName
      self.publicKey = publicKey
      self.commitment = commitment
    }
  }

  public struct PairResponse: Codable, Equatable, Sendable {
    public var hostID: String
    public var hostName: String
    public var publicKey: String
    public var nonce: String
    public init(hostID: String, hostName: String, publicKey: String, nonce: String) {
      self.hostID = hostID
      self.hostName = hostName
      self.publicKey = publicKey
      self.nonce = nonce
    }
  }

  public struct PairReveal: Codable, Equatable, Sendable {
    public var nonce: String
    public init(nonce: String) {
      self.nonce = nonce
    }
  }

  public struct PairResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var reason: String?
    public init(accepted: Bool, reason: String? = nil) {
      self.accepted = accepted
      self.reason = reason
    }
  }

  public struct Geometry: Codable, Equatable, Sendable {
    public var surfaceWidth: Double
    public var surfaceHeight: Double
    public init(surfaceWidth: Double, surfaceHeight: Double) {
      self.surfaceWidth = surfaceWidth
      self.surfaceHeight = surfaceHeight
    }
  }

  public struct FrontApp: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    public init(appID: String, name: String) {
      self.appID = appID
      self.name = name
    }
    private enum CodingKeys: String, CodingKey { case appID, bundleID, name }
    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      appID =
        try values.decodeIfPresent(String.self, forKey: .appID)
        ?? values.decode(String.self, forKey: .bundleID)
      name = try values.decode(String.self, forKey: .name)
    }
    public func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(appID, forKey: .appID)
      try values.encode(name, forKey: .name)
    }
  }

  case hello(Hello)
  case helloAck(HelloAck)
  case geometry(Geometry)
  case ping
  case probe(sentAtNs: UInt64)
  case probeReply(sentAtNs: UInt64)
  case gesture(Gesture)
  case frontApp(FrontApp)
  case pairRequest(PairRequest)
  case pairResponse(PairResponse)
  case pairReveal(PairReveal)
  case pairResult(PairResult)

  private enum CodingKeys: String, CodingKey {
    case type, hello, helloAck, geometry, sentAtNs, gesture, frontApp, pairRequest, pairResponse,
      pairReveal, pairResult
  }
  private enum Kind: String, Codable, CaseIterable {
    case hello, helloAck, geometry, ping, probe, probeReply, gesture, frontApp, pairRequest, pairResponse,
      pairReveal, pairResult
  }

  static func isKnownType(_ value: String) -> Bool { Kind(rawValue: value) != nil }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .hello: self = .hello(try container.decode(Hello.self, forKey: .hello))
    case .helloAck: self = .helloAck(try container.decode(HelloAck.self, forKey: .helloAck))
    case .geometry: self = .geometry(try container.decode(Geometry.self, forKey: .geometry))
    case .ping: self = .ping
    case .probe: self = .probe(sentAtNs: try container.decode(UInt64.self, forKey: .sentAtNs))
    case .probeReply: self = .probeReply(sentAtNs: try container.decode(UInt64.self, forKey: .sentAtNs))
    case .gesture: self = .gesture(try container.decode(Gesture.self, forKey: .gesture))
    case .frontApp: self = .frontApp(try container.decode(FrontApp.self, forKey: .frontApp))
    case .pairRequest: self = .pairRequest(try container.decode(PairRequest.self, forKey: .pairRequest))
    case .pairResponse: self = .pairResponse(try container.decode(PairResponse.self, forKey: .pairResponse))
    case .pairReveal: self = .pairReveal(try container.decode(PairReveal.self, forKey: .pairReveal))
    case .pairResult: self = .pairResult(try container.decode(PairResult.self, forKey: .pairResult))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello(let value):
      try container.encode(Kind.hello, forKey: .type)
      try container.encode(value, forKey: .hello)
    case .helloAck(let value):
      try container.encode(Kind.helloAck, forKey: .type)
      try container.encode(value, forKey: .helloAck)
    case .geometry(let value):
      try container.encode(Kind.geometry, forKey: .type)
      try container.encode(value, forKey: .geometry)
    case .ping:
      try container.encode(Kind.ping, forKey: .type)
    case .probe(let sentAtNs):
      try container.encode(Kind.probe, forKey: .type)
      try container.encode(sentAtNs, forKey: .sentAtNs)
    case .probeReply(let sentAtNs):
      try container.encode(Kind.probeReply, forKey: .type)
      try container.encode(sentAtNs, forKey: .sentAtNs)
    case .gesture(let gesture):
      try container.encode(Kind.gesture, forKey: .type)
      try container.encode(gesture, forKey: .gesture)
    case .frontApp(let frontApp):
      try container.encode(Kind.frontApp, forKey: .type)
      try container.encode(frontApp, forKey: .frontApp)
    case .pairRequest(let request):
      try container.encode(Kind.pairRequest, forKey: .type)
      try container.encode(request, forKey: .pairRequest)
    case .pairResponse(let response):
      try container.encode(Kind.pairResponse, forKey: .type)
      try container.encode(response, forKey: .pairResponse)
    case .pairReveal(let reveal):
      try container.encode(Kind.pairReveal, forKey: .type)
      try container.encode(reveal, forKey: .pairReveal)
    case .pairResult(let result):
      try container.encode(Kind.pairResult, forKey: .type)
      try container.encode(result, forKey: .pairResult)
    }
  }
}

public struct ControlFramer: Sendable {
  public enum Error: Swift.Error, Equatable {
    case oversized(Int)
    case invalidLength(UInt32)
    case malformed
  }
  public static let maximumMessageSize = 64 * 1024
  private var bytes: [UInt8] = []
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public enum AppendOneResult: Sendable, Equatable {
    case message(ControlMessage)
    case skipped
    case needMore
  }

  public init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    decoder = JSONDecoder()
  }

  public func encode(_ message: ControlMessage) -> [UInt8] {
    let body = try! encoder.encode(message)
    precondition(body.count <= Self.maximumMessageSize, "control message exceeds 64 KiB")
    let length = UInt32(body.count)
    return [
      UInt8(length & 0xff), UInt8((length >> 8) & 0xff), UInt8((length >> 16) & 0xff),
      UInt8((length >> 24) & 0xff),
    ] + body
  }

  public mutating func append(_ chunk: [UInt8]) throws -> [ControlMessage] {
    bytes.append(contentsOf: chunk)
    var messages: [ControlMessage] = []
    while true {
      guard bytes.count >= 4 else { break }
      let length = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
      guard length <= Self.maximumMessageSize else { throw Error.oversized(Int(length)) }
      guard length >= 2 else { throw Error.invalidLength(length) }
      let total = 4 + Int(length)
      guard bytes.count >= total else { break }
      let body = bytes[4..<total]
      bytes.removeFirst(total)
      guard let object = try? JSONSerialization.jsonObject(with: Data(body)),
        let dictionary = object as? [String: Any], let type = dictionary["type"] as? String
      else { throw Error.malformed }
      guard ControlMessage.isKnownType(type) else { continue }
      do { messages.append(try decoder.decode(ControlMessage.self, from: Data(body))) } catch {
        if type == "gesture",
          let gesture = dictionary["gesture"] as? [String: Any],
          let gestureType = gesture["type"] as? String,
          !Gesture.isKnownType(gestureType)
        {
          continue
        }
        throw Error.malformed
      }
    }
    return messages
  }

  /// Decodes at most one frame. This is used by the session boundary so a
  /// plaintext helloAck cannot make the framer inspect the sealed bytes that
  /// follow it in the same socket read.
  public mutating func appendOne(_ chunk: [UInt8]) throws -> AppendOneResult {
    bytes.append(contentsOf: chunk)
    guard bytes.count >= 4 else { return .needMore }
    let length = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    guard length <= Self.maximumMessageSize else { throw Error.oversized(Int(length)) }
    guard length >= 2 else { throw Error.invalidLength(length) }
    let total = 4 + Int(length)
    guard bytes.count >= total else { return .needMore }
    let body = Data(bytes[4..<total])
    bytes.removeFirst(total)
    guard let object = try? JSONSerialization.jsonObject(with: body),
      let dictionary = object as? [String: Any], let type = dictionary["type"] as? String
    else { throw Error.malformed }
    guard ControlMessage.isKnownType(type) else { return .skipped }
    do { return .message(try decoder.decode(ControlMessage.self, from: body)) } catch {
      if type == "gesture", let gesture = dictionary["gesture"] as? [String: Any],
        let gestureType = gesture["type"] as? String, !Gesture.isKnownType(gestureType)
      {
        return .skipped
      }
      throw Error.malformed
    }
  }

  public mutating func takeBufferedBytes() -> Data {
    let result = Data(bytes)
    bytes.removeAll(keepingCapacity: true)
    return result
  }

  public static func encode(_ message: ControlMessage) -> [UInt8] { ControlFramer().encode(message) }

  public mutating func feed(_ chunk: [UInt8]) throws -> [ControlMessage] { try append(chunk) }
  public var bufferedByteCount: Int { bytes.count }
}
