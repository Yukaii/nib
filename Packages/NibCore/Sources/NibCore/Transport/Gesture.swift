import Foundation

/// Finger input sent over the reliable control channel.
public enum Gesture: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case began, changed, ended, cancelled
  }

  public enum Modifier: String, Codable, Sendable {
    case command, option, control
  }

  case scroll(dx: Double, dy: Double, phase: Phase)
  case zoom(scaleDelta: Double, phase: Phase, modifier: Modifier)
  case undo
  case redo

  private enum CodingKeys: String, CodingKey { case type, dx, dy, scaleDelta, phase, modifier }
  private enum Kind: String, Codable { case scroll, zoom, undo, redo }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .type) {
    case .scroll:
      self = .scroll(
        dx: try values.decode(Double.self, forKey: .dx),
        dy: try values.decode(Double.self, forKey: .dy),
        phase: try values.decode(Phase.self, forKey: .phase))
    case .zoom:
      self = .zoom(
        scaleDelta: try values.decode(Double.self, forKey: .scaleDelta),
        phase: try values.decode(Phase.self, forKey: .phase),
        modifier: try values.decode(Modifier.self, forKey: .modifier))
    case .undo: self = .undo
    case .redo: self = .redo
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .scroll(let dx, let dy, let phase):
      try values.encode(Kind.scroll, forKey: .type)
      try values.encode(dx, forKey: .dx)
      try values.encode(dy, forKey: .dy)
      try values.encode(phase, forKey: .phase)
    case .zoom(let scaleDelta, let phase, let modifier):
      try values.encode(Kind.zoom, forKey: .type)
      try values.encode(scaleDelta, forKey: .scaleDelta)
      try values.encode(phase, forKey: .phase)
      try values.encode(modifier, forKey: .modifier)
    case .undo: try values.encode(Kind.undo, forKey: .type)
    case .redo: try values.encode(Kind.redo, forKey: .type)
    }
  }
}
