#if os(macOS)
  import Foundation
  import Network

  /// Mac-side usbmuxd client. Device discovery and each device connection are
  /// separate sockets, as required by the usbmux protocol.
  @MainActor
  public final class UsbmuxClient {
    public struct Device: Sendable, Equatable {
      public let id: UInt32
      public let connectionType: String?
      public init(id: UInt32, connectionType: String?) {
        self.id = id
        self.connectionType = connectionType
      }
    }

    public typealias DeviceHandler = @MainActor (Device, NWConnection) -> Void
    public var onDeviceConnection: DeviceHandler?
    public var onDeviceConnectionEnded: (@MainActor (Device, NWConnection) -> Void)?
    public private(set) var devices: [UInt32: Device] = [:]

    private let queue = DispatchQueue(label: "dev.yukai.nib.usbmux")
    private var listenerConnection: NWConnection?
    private var deviceConnections: [UInt32: NWConnection] = [:]
    private var retryTasks: [UInt32: Task<Void, Never>] = [:]
    private var tag: UInt32 = 1
    private var listenBytes = Data()

    public init() {}

    /// Called by the receiver when it has dropped a successfully connected USB stream.
    public func deviceConnectionEnded(_ device: Device, connection: NWConnection) {
      guard deviceConnections[device.id] === connection else { return }
      deviceConnections[device.id] = nil
      onDeviceConnectionEnded?(device, connection)
      if let device = devices[device.id] { scheduleConnect(device) }
    }

    public func start() {
      stop()
      let connection = NWConnection(to: .unix(path: "/var/run/usbmuxd"), using: .tcp)
      listenerConnection = connection
      connection.stateUpdateHandler = { [weak self] state in
        if case .ready = state {
          Task { @MainActor [weak self] in self?.beginListen() }
        }
      }
      connection.start(queue: queue)
    }

    public func stop() {
      listenerConnection?.cancel()
      listenerConnection = nil
      for connection in deviceConnections.values { connection.cancel() }
      deviceConnections.removeAll()
      for task in retryTasks.values { task.cancel() }
      retryTasks.removeAll()
      devices.removeAll()
      listenBytes.removeAll()
    }

    private func beginListen() {
      guard let connection = listenerConnection else { return }
      let request = UsbmuxPacket.listenRequest(tag: nextTag())
      connection.send(
        content: request,
        completion: .contentProcessed { [weak self] error in
          if error != nil { Task { @MainActor [weak self] in self?.start() } }
        })
      receiveListen(from: connection)
    }

    private func receiveListen(from expected: NWConnection) {
      expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        [weak self] data, _, complete, error in
        Task { @MainActor [weak self] in
          guard let self, self.listenerConnection === expected else { return }
          if let data { self.listenBytes.append(data) }
          do { try self.consumeListenPackets() } catch {
            expected.cancel()
            self.start()
            return
          }
          if complete || error != nil { self.start() } else { self.receiveListen(from: expected) }
        }
      }
    }

    private func consumeListenPackets() throws {
      while listenBytes.count >= UsbmuxPacket.headerLength {
        let length =
          UInt32(listenBytes[0]) | UInt32(listenBytes[1]) << 8
          | UInt32(listenBytes[2]) << 16 | UInt32(listenBytes[3]) << 24
        guard length >= UsbmuxPacket.headerLength, Int(length) <= 1_048_576 else {
          throw UsbmuxPacket.Error.invalidHeader
        }
        guard listenBytes.count >= Int(length) else { return }
        let packet = try UsbmuxPacket.decode(listenBytes.prefix(Int(length)))
        listenBytes.removeFirst(Int(length))
        switch packet.message {
        case .attached(let id, let type) where type == "USB":
          let device = Device(id: id, connectionType: type)
          devices[id] = device
          scheduleConnect(device)
        case .detached(let id):
          devices[id] = nil
          deviceConnections[id]?.cancel()
          deviceConnections[id] = nil
          retryTasks[id]?.cancel()
          retryTasks[id] = nil
        default: break
        }
      }
    }

    private func scheduleConnect(_ device: Device) {
      retryTasks[device.id]?.cancel()
      retryTasks[device.id] = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          self?.connect(device)
          try? await Task.sleep(for: .seconds(2))
          guard let self, self.devices[device.id] != nil, self.deviceConnections[device.id] == nil else {
            return
          }
        }
      }
    }

    private func connect(_ device: Device) {
      guard deviceConnections[device.id] == nil else { return }
      let connection = NWConnection(to: .unix(path: "/var/run/usbmuxd"), using: .tcp)
      deviceConnections[device.id] = connection
      let request = UsbmuxPacket.connectRequest(deviceID: device.id, tag: nextTag())
      connection.stateUpdateHandler = { [weak self] state in
        if case .failed = state {
          Task { @MainActor [weak self] in self?.deviceConnectionFailed(device, connection: connection) }
        } else if case .cancelled = state {
          Task { @MainActor [weak self] in self?.deviceConnectionFailed(device, connection: connection) }
        }
        if case .ready = state {
          connection.send(content: request, completion: .contentProcessed { _ in })
          Task { @MainActor [weak self] in
            self?.receiveConnectResult(connection, device: device)
          }
        }
      }
      connection.start(queue: queue)
    }

    private func receiveConnectResult(_ connection: NWConnection, device: Device) {
      connection.receive(
        minimumIncompleteLength: UsbmuxPacket.headerLength, maximumLength: UsbmuxPacket.headerLength
      ) {
        [weak self] data, _, _, error in
        Task { @MainActor [weak self] in
          guard let self, self.deviceConnections[device.id] === connection, error == nil,
            let header = data, header.count == UsbmuxPacket.headerLength
          else {
            self?.deviceConnectionFailed(device, connection: connection)
            return
          }
          let length =
            UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16
            | UInt32(header[3]) << 24
          let bodyLength = Int(length) - UsbmuxPacket.headerLength
          guard bodyLength > 0, bodyLength <= 1_048_576 else {
            self.deviceConnectionFailed(device, connection: connection)
            return
          }
          self.receiveConnectBody(
            connection, device: device, header: header, bodyLength: bodyLength)
        }
      }
    }

    private func receiveConnectBody(
      _ connection: NWConnection, device: Device, header: Data, bodyLength: Int
    ) {
      connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) {
        [weak self] data, _, _, error in
        Task { @MainActor [weak self] in
          guard let self, self.deviceConnections[device.id] === connection, error == nil,
            let body = data, body.count == bodyLength
          else {
            self?.deviceConnectionFailed(device, connection: connection)
            return
          }
          var packetData = header
          packetData.append(body)
          guard let packet = try? UsbmuxPacket.decode(packetData),
            case .result(let code) = packet.message, code == 0
          else {
            self.deviceConnectionFailed(device, connection: connection)
            return
          }
          self.onDeviceConnection?(device, connection)
        }
      }
    }

    private func deviceConnectionFailed(_ device: Device, connection: NWConnection) {
      guard deviceConnections[device.id] === connection else { return }
      connection.cancel()
      deviceConnections[device.id] = nil
      onDeviceConnectionEnded?(device, connection)
    }

    private func nextTag() -> UInt32 {
      defer { tag &+= 1 }
      return tag
    }
  }
#endif
