#if os(macOS)
  import AppKit
  import CoreGraphics

  /// Builds the Quartz event sequence for one Pencil stream.
  public struct TabletEventBuilder {
    public static let defaultDeviceID: Int64 = 0x4E49_4201

    private static let penPointerType: Int64 = 1
    private static let eraserPointerType: Int64 = 3
    // Quartz's capability mask is a bit mask. Bits 0 and 1 advertise pressure and tilt.
    private static let capabilityMask: Int64 = 0b11

    public let deviceID: Int64
    public private(set) var inProximity = false

    public init(deviceID: Int64 = TabletEventBuilder.defaultDeviceID) {
      self.deviceID = deviceID
    }

    public mutating func events(for sample: PenSample, at point: CGPoint) -> [CGEvent] {
      let pointerType = sample.buttons.contains(.eraser) ? Self.eraserPointerType : Self.penPointerType
      var result: [CGEvent] = []

      if sample.kind != .proximityExit && !inProximity {
        result.append(makeProximityEvent(entering: true, pointerType: pointerType))
        inProximity = true
      }

      switch sample.kind {
      case .hover:
        result.append(makePointEvent(type: .mouseMoved, sample: sample, point: point))
      case .down:
        result.append(makePointEvent(type: .leftMouseDown, sample: sample, point: point))
      case .move:
        result.append(makePointEvent(type: .leftMouseDragged, sample: sample, point: point))
      case .up:
        result.append(makePointEvent(type: .leftMouseUp, sample: sample, point: point))
      case .cancel:
        if sample.pressure > 0 || inProximity {
          result.append(makePointEvent(type: .leftMouseUp, sample: sample, point: point))
        }
      case .proximityExit:
        if inProximity {
          result.append(makeProximityEvent(entering: false, pointerType: pointerType))
          inProximity = false
        }
      }

      return result
    }

    private func makePointEvent(type: CGEventType, sample: PenSample, point: CGPoint) -> CGEvent {
      let pressure = Double(min(1, max(0, sample.pressure)))
      let tilt = TabletMath.tilt(altitude: Double(sample.altitude), azimuth: Double(sample.azimuth))
      let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
      )!
      event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
      event.setDoubleValueField(.mouseEventPressure, value: pressure)
      event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
      event.setDoubleValueField(.tabletEventTiltX, value: tilt.x)
      event.setDoubleValueField(.tabletEventTiltY, value: tilt.y)
      event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
      return event
    }

    private func makeProximityEvent(entering: Bool, pointerType: Int64) -> CGEvent {
      let event = CGEvent(source: nil)!
      event.type = .tabletProximity
      event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
      event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: deviceID)
      event.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType)
      event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.capabilityMask)
      event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
      return event
    }
  }
#endif
