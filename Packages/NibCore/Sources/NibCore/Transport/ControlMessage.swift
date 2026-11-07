import Foundation

/// Reliable control-channel messages exchanged before and alongside the UDP sample stream.
public enum ControlMessage: Codable, Equatable, Sendable {
  public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: UInt8
    public var appVersion: String
    public var deviceName: String
    public var surfaceWidth: Double
    public var surfaceHeight: Double

    public init(
      protocolVersion: UInt8 = PenSample.version, appVersion: String, deviceName: String,
      surfaceWidth: Double,
      surfaceHeight: Double
    ) {
      self.protocolVersion = protocolVersion
      self.appVersion = appVersion
      self.deviceName = deviceName
      self.surfaceWidth = surfaceWidth
      self.surfaceHeight = surfaceHeight
    }
  }

  public struct HelloAck: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var reason: String?
    public var udpPort: UInt16
    public var displayWidth: Double
    public var displayHeight: Double

    public init(
      accepted: Bool, reason: String? = nil, udpPort: UInt16 = 0, displayWidth: Double = 0,
      displayHeight: Double = 0
    ) {
      self.accepted = accepted
      self.reason = reason
      self.udpPort = udpPort
      self.displayWidth = displayWidth
      self.displayHeight = displayHeight
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

  case hello(Hello)
  case helloAck(HelloAck)
  case geometry(Geometry)
  case ping
  case probe(sentAtNs: UInt64)
  case probeReply(sentAtNs: UInt64)

  private enum CodingKeys: String, CodingKey { case type, hello, helloAck, geometry, sentAtNs }
  private enum Kind: String, Codable { case hello, helloAck, geometry, ping, probe, probeReply }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .hello: self = .hello(try container.decode(Hello.self, forKey: .hello))
    case .helloAck: self = .helloAck(try container.decode(HelloAck.self, forKey: .helloAck))
    case .geometry: self = .geometry(try container.decode(Geometry.self, forKey: .geometry))
    case .ping: self = .ping
    case .probe: self = .probe(sentAtNs: try container.decode(UInt64.self, forKey: .sentAtNs))
    case .probeReply: self = .probeReply(sentAtNs: try container.decode(UInt64.self, forKey: .sentAtNs))
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

  public init() {
    encoder = JSONEncoder()
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
      do { messages.append(try decoder.decode(ControlMessage.self, from: Data(body))) } catch {
        throw Error.malformed
      }
      bytes.removeFirst(total)
    }
    return messages
  }

  public static func encode(_ message: ControlMessage) -> [UInt8] { ControlFramer().encode(message) }

  public mutating func feed(_ chunk: [UInt8]) throws -> [ControlMessage] { try append(chunk) }
  public var bufferedByteCount: Int { bytes.count }
}
