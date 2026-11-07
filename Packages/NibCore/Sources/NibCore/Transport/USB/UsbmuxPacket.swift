import Foundation

/// The packet envelope used by usbmuxd's plist protocol.
///
/// usbmuxd uses a little-endian 16-byte header, while the port inside a
/// Connect plist is a network-order UInt16 widened to a plist integer.
public struct UsbmuxPacket: Sendable, Equatable {
  public static let headerLength = 16
  public static let protocolVersion: UInt32 = 1
  public static let plistMessage: UInt32 = 8

  public enum Message: Sendable, Equatable {
    case listen
    case connect(deviceID: UInt32, port: UInt16)
    case attached(deviceID: UInt32, connectionType: String?)
    case detached(deviceID: UInt32)
    case result(code: Int32)
    case unknown(String)
  }

  public let tag: UInt32
  public let message: Message

  public init(tag: UInt32, message: Message) {
    self.tag = tag
    self.message = message
  }

  public static func listenRequest(tag: UInt32 = 1) -> Data {
    encode(
      tag: tag,
      plist: [
        "Message": "Listen",
        "ClientVersionString": "Nib",
        "ProgName": "Nib",
      ])
  }

  public static func connectRequest(deviceID: UInt32, port: UInt16 = 47811, tag: UInt32 = 1) -> Data {
    // libusbmuxd specifies PortNumber as a network-order uint16. Property
    // lists carry an integer, so retain the byte-swapped value when widening.
    let networkPort = Int(UInt16(port).bigEndian)
    return encode(
      tag: tag,
      plist: [
        "Message": "Connect",
        "DeviceID": Int(deviceID),
        "PortNumber": networkPort,
      ])
  }

  public static func decode(_ data: Data) throws -> UsbmuxPacket {
    guard data.count >= headerLength else { throw Error.truncatedHeader }
    let length = loadUInt32(data, at: 0)
    guard length >= headerLength, Int(length) <= data.count else {
      throw Error.truncatedBody
    }
    guard loadUInt32(data, at: 4) == protocolVersion,
      loadUInt32(data, at: 8) == plistMessage
    else { throw Error.invalidHeader }
    let tag = loadUInt32(data, at: 12)
    let body = data.subdata(in: headerLength..<Int(length))
    guard
      let plist = try PropertyListSerialization.propertyList(
        from: body, options: [], format: nil) as? [String: Any],
      let name = plist["Message"] as? String
    else { throw Error.invalidPlist }
    let message: Message
    switch name {
    case "Listen": message = .listen
    case "Connect":
      guard let deviceID = integer(plist["DeviceID"]), let port = integer(plist["PortNumber"])
      else { throw Error.invalidPlist }
      message = .connect(
        deviceID: UInt32(truncatingIfNeeded: deviceID), port: UInt16(truncatingIfNeeded: port).bigEndian)
    case "Attached":
      guard let deviceID = integer((plist["Device"] as? [String: Any])?["DeviceID"])
      else { throw Error.invalidPlist }
      let device = plist["Device"] as? [String: Any]
      message = .attached(
        deviceID: UInt32(truncatingIfNeeded: deviceID), connectionType: device?["ConnectionType"] as? String)
    case "Detached":
      guard let deviceID = integer(plist["DeviceID"]) else { throw Error.invalidPlist }
      message = .detached(deviceID: UInt32(truncatingIfNeeded: deviceID))
    case "Result":
      guard let code = integer(plist["Number"]) else { throw Error.invalidPlist }
      message = .result(code: Int32(truncatingIfNeeded: code))
    default: message = .unknown(name)
    }
    return UsbmuxPacket(tag: tag, message: message)
  }

  public enum Error: Swift.Error, Equatable {
    case truncatedHeader, truncatedBody, invalidHeader, invalidPlist
  }

  private static func encode(tag: UInt32, plist: [String: Any]) -> Data {
    let body = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    var data = Data()
    append(UInt32(headerLength + body.count), to: &data)
    append(protocolVersion, to: &data)
    append(plistMessage, to: &data)
    append(tag, to: &data)
    data.append(body)
    return data
  }
}

/// Incrementally consumes one Connect result packet without swallowing bytes
/// belonging to the iPad stream that follows it.
public struct UsbmuxConnectResultFramer: Sendable {
  private var bytes = Data()

  public init() {}

  public mutating func append(_ chunk: Data) throws -> UsbmuxPacket? {
    bytes.append(chunk)
    guard bytes.count >= UsbmuxPacket.headerLength else { return nil }
    let length =
      UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
      | UInt32(bytes[3]) << 24
    guard length >= UsbmuxPacket.headerLength, length <= 1_048_576 else {
      throw UsbmuxPacket.Error.invalidHeader
    }
    guard bytes.count >= Int(length) else { return nil }
    let packet = try UsbmuxPacket.decode(bytes.prefix(Int(length)))
    bytes.removeFirst(Int(length))
    return packet
  }

  public var bufferedByteCount: Int { bytes.count }
}

private func integer(_ value: Any?) -> Int64? {
  if let value = value as? NSNumber { return value.int64Value }
  if let value = value as? Int { return Int64(value) }
  return nil
}

private func loadUInt32(_ data: Data, at offset: Int) -> UInt32 {
  UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
    | UInt32(data[offset + 3]) << 24
}

private func append(_ value: UInt32, to data: inout Data) {
  data.append(UInt8(truncatingIfNeeded: value))
  data.append(UInt8(truncatingIfNeeded: value >> 8))
  data.append(UInt8(truncatingIfNeeded: value >> 16))
  data.append(UInt8(truncatingIfNeeded: value >> 24))
}
