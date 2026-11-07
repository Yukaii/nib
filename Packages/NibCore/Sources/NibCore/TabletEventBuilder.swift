#if os(macOS)
  import AppKit
  import CoreGraphics

  /// Builds the Quartz event sequence for one Pencil stream.
  public struct TabletEventBuilder {
    public static let defaultDeviceID: Int64 = 0x4E49_4201

    private static let penPointerType: Int64 = 1
    private static let eraserPointerType: Int64 = 3
    private static let pointerID: Int64 = 0x4E49_4201
    private static let vendorID: Int64 = 0x4E49_4202
    // IOLLEvent.h capability bits: device id, absolute axes, buttons, tilt and pressure.
    private static let capabilityDeviceID: Int64 = 0x0001
    private static let capabilityAbsoluteX: Int64 = 0x0002
    private static let capabilityAbsoluteY: Int64 = 0x0004
    private static let capabilityButtons: Int64 = 0x0040
    private static let capabilityTiltX: Int64 = 0x0080
    private static let capabilityTiltY: Int64 = 0x0100
    private static let capabilityPressure: Int64 = 0x0400
    private static let capabilityMask =
      capabilityDeviceID | capabilityAbsoluteX | capabilityAbsoluteY
      | capabilityButtons | capabilityTiltX | capabilityTiltY | capabilityPressure

    public let deviceID: Int64
    public private(set) var inProximity = false
    public private(set) var isButtonDown = false
    private var activePointerType: Int64?

    public init(deviceID: Int64 = TabletEventBuilder.defaultDeviceID) {
      self.deviceID = deviceID
    }

    public mutating func events(for sample: PenSample, at point: CGPoint) -> [CGEvent] {
      guard !sample.flags.contains(.predicted) else { return [] }
      if (sample.kind == .up || sample.kind == .cancel) && !isButtonDown { return [] }
      let pointerType = sample.buttons.contains(.eraser) ? Self.eraserPointerType : Self.penPointerType
      var result: [CGEvent] = []

      if inProximity, let activePointerType, activePointerType != pointerType, !isButtonDown {
        result.append(makeProximityEvent(entering: false, pointerType: activePointerType))
        inProximity = false
        self.activePointerType = nil
      }

      if sample.kind != .proximityExit && !inProximity {
        result.append(makeProximityEvent(entering: true, pointerType: pointerType))
        inProximity = true
        activePointerType = pointerType
      }

      switch sample.kind {
      case .hover:
        if isButtonDown {
          result.append(makePointEvent(type: .leftMouseUp, sample: sample, point: point, buttons: 0))
          isButtonDown = false
          result.append(contentsOf: restartProximityIfNeeded(requestedPointerType: pointerType))
        }
        result.append(makePointEvent(type: .mouseMoved, sample: sample, point: point, buttons: 0))
      case .down:
        if isButtonDown {
          result.append(makePointEvent(type: .leftMouseDragged, sample: sample, point: point, buttons: 1))
        } else {
          result.append(makePointEvent(type: .leftMouseDown, sample: sample, point: point, buttons: 1))
          isButtonDown = true
        }
      case .move:
        if !isButtonDown {
          result.append(makePointEvent(type: .leftMouseDown, sample: sample, point: point, buttons: 1))
          isButtonDown = true
        }
        result.append(makePointEvent(type: .leftMouseDragged, sample: sample, point: point, buttons: 1))
      case .up:
        if isButtonDown {
          result.append(makePointEvent(type: .leftMouseUp, sample: sample, point: point, buttons: 0))
          isButtonDown = false
          result.append(contentsOf: restartProximityIfNeeded(requestedPointerType: pointerType))
        }
      case .cancel:
        if isButtonDown {
          result.append(makePointEvent(type: .leftMouseUp, sample: sample, point: point, buttons: 0))
          isButtonDown = false
          result.append(contentsOf: restartProximityIfNeeded(requestedPointerType: pointerType))
        }
      case .proximityExit:
        if isButtonDown {
          result.append(makePointEvent(type: .leftMouseUp, sample: sample, point: point, buttons: 0))
          isButtonDown = false
        }
        if inProximity {
          result.append(makeProximityEvent(entering: false, pointerType: activePointerType ?? pointerType))
          inProximity = false
          activePointerType = nil
        }
      }

      return result
    }

    private mutating func restartProximityIfNeeded(requestedPointerType: Int64) -> [CGEvent] {
      guard inProximity, let activePointerType, activePointerType != requestedPointerType else { return [] }
      let exit = makeProximityEvent(entering: false, pointerType: activePointerType)
      inProximity = false
      self.activePointerType = nil
      let enter = makeProximityEvent(entering: true, pointerType: requestedPointerType)
      inProximity = true
      self.activePointerType = requestedPointerType
      return [exit, enter]
    }

    private func makePointEvent(type: CGEventType, sample: PenSample, point: CGPoint, buttons: Int64)
      -> CGEvent
    {
      let pressure = Double(min(1, max(0, sample.pressure)))
      let tilt = TabletMath.tilt(altitude: Double(sample.altitude), azimuth: Double(sample.azimuth))
      let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
      )!
      event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
      event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
      event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
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
      event.setIntegerValueField(.tabletProximityEventPointerID, value: Self.pointerID)
      event.setIntegerValueField(.tabletProximityEventVendorID, value: Self.vendorID)
      event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.capabilityMask)
      event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
      return event
    }
  }
#endif
