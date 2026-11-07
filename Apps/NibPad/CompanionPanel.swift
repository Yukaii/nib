import NibCore
import SwiftUI
import UIKit

struct CompanionPanel: View {
  @Bindable var store: PadSettingsStore
  let linkState: PenLinkState
  let profileName: String
  let frontApp: ControlMessage.FrontApp
  let hostInfo: ControlMessage.HostInfo?
  let showIntroduction: () -> Void
  let changeMac: () -> Void
  let pressureResult: PressureCheckResult
  @Binding var showsHUD: Bool
  @State private var testRaw: Double = 0.5
  @State private var editing: ProfileTarget?
  @State private var confirmsReset = false

  private struct ProfileTarget: Identifiable { let id: UUID }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          VStack(alignment: .leading) {
            Text("Nib Companion").font(.title2.bold())
            Text(plainStatus).font(.footnote).foregroundStyle(.secondary)
            if let hostInfo {
              Text(
                "Connected to \(hostInfo.name) (\(hostInfo.platform.displayName), Nib \(hostInfo.appVersion))"
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("Done") { NotificationCenter.default.post(name: .closeCompanionPanel, object: nil) }
        }
        pressureSection
        if pressureResult == .noPressure {
          Text(
            "This Pencil doesn’t report pressure. Nib needs Apple Pencil (1st gen), Apple Pencil 2 or Apple Pencil Pro."
          )
          .font(.footnote).foregroundStyle(.orange)
        }
        profilesSection
        Toggle("Debug HUD", isOn: $showsHUD)
        Button("Change Mac") { changeMac() }
        Button("Show introduction again") { showIntroduction() }
        HStack {
          Text("Edge brightness")
          Slider(value: edgeBrightness, in: 0...1)
          Text(store.settings.edgeBrightness, format: .percent.precision(.fractionLength(0)))
            .frame(width: 44, alignment: .trailing)
        }
      }
      .padding(24)
    }
    .background(.black.opacity(0.92))
    .foregroundStyle(.white)
    .tint(.cyan)
  }

  private var plainStatus: String {
    linkState.userFacingText()
  }

  private var pressureSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Pressure").font(.headline)
      HStack {
        ForEach([(PadSettings.Pressure.soft, "Soft"), (.linear, "Linear"), (.firm, "Firm")], id: \.1) {
          preset, title in
          Button(title) { store.settings.pressure = preset }
            .buttonStyle(.borderedProminent)
            .opacity(store.settings.pressure == preset ? 1 : 0.55)
        }
      }
      HStack {
        Text("Soft")
        Slider(value: softness, in: -1...1)
        Text("Firm")
      }
      HStack {
        Text("Min \(store.settings.pressure.minimum, format: .number.precision(.fractionLength(2)))")
        Slider(value: minimum, in: 0...0.5)
        Text("Max \(store.settings.pressure.maximum, format: .number.precision(.fractionLength(2)))")
        Slider(value: maximum, in: 0.5...1)
      }
      Text("Curve").font(.subheadline)
      CurvePreview(pressure: store.settings.pressure)
        .frame(height: 100)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      Text("Test strip").font(.subheadline)
      ZStack(alignment: .leading) {
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
            Capsule().fill(.cyan).frame(
              width: proxy.size.width * CGFloat(PressureCurve.apply(Float(testRaw), store.settings.pressure)))
            Circle().fill(.white).frame(width: 22, height: 22)
              .offset(x: proxy.size.width * CGFloat(testRaw) - 11)
          }
        }
        PencilPressureProbe { testRaw = Double($0) }
      }
      .frame(height: 44)
      Text("Press the Pencil on the strip: dot = raw force, bar = what the Mac receives.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var activeID: UUID { store.settings.profile(forAppID: frontApp.appID).id }

  private var profilesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Profiles").font(.headline)
      Text(
        "Active: \(profileName) (front app: \(frontApp.appID.isEmpty ? "none reported" : frontApp.name))"
      )
      .font(.footnote).foregroundStyle(.secondary)
      ForEach(store.settings.profiles) { profile in
        Button {
          editing = ProfileTarget(id: profile.id)
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.name)
              Text(profileSummary(profile)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if profile.id == activeID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan) }
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
          }
          .padding(12)
          .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
      }
      HStack {
        Button("Add profile") { editing = ProfileTarget(id: store.settings.addProfile()) }
        Spacer()
        Button("Reset to presets", role: .destructive) { confirmsReset = true }
      }
      .buttonStyle(.bordered)
    }
    .sheet(item: $editing) { target in
      ProfileEditor(store: store, profileID: target.id, frontApp: frontApp, hostInfo: hostInfo)
    }
    .confirmationDialog(
      "Replace all profiles with the Default, Krita, Photoshop and Affinity presets?",
      isPresented: $confirmsReset, titleVisibility: .visible
    ) {
      Button("Reset to presets", role: .destructive) { store.settings.resetProfilesToPresets() }
    }
  }

  private func profileSummary(_ profile: PadSettings.Profile) -> String {
    let apps =
      store.settings.isDefault(profile.id) ? "Fallback" : profile.appIDPrefixes.joined(separator: ", ")
    return "\(apps.isEmpty ? "No apps" : apps) · \(profile.buttons.count) buttons"
  }

  private var softness: Binding<Double> {
    Binding(get: { store.settings.pressure.softness }, set: { store.settings.pressure.softness = $0 })
  }
  private var minimum: Binding<Double> {
    Binding(
      get: { store.settings.pressure.minimum },
      set: { store.settings.pressure.minimum = min($0, store.settings.pressure.maximum - 0.01) })
  }
  private var maximum: Binding<Double> {
    Binding(
      get: { store.settings.pressure.maximum },
      set: { store.settings.pressure.maximum = max($0, store.settings.pressure.minimum + 0.01) })
  }
  private var edgeBrightness: Binding<Double> {
    Binding(
      get: { store.settings.edgeBrightness },
      set: { store.settings.edgeBrightness = min(max($0, 0), 1) })
  }
}

private struct CurvePreview: View {
  let pressure: PadSettings.Pressure
  var body: some View {
    Canvas { context, size in
      var path = Path()
      for index in 0...100 {
        let raw = Float(index) / 100
        let point = CGPoint(
          x: CGFloat(raw) * size.width, y: size.height * (1 - CGFloat(PressureCurve.apply(raw, pressure))))
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      context.stroke(path, with: .color(.cyan), lineWidth: 3)
    }
  }
}

/// Reports real Pencil force (not position) so the curve can be calibrated by hand.
private struct PencilPressureProbe: UIViewRepresentable {
  let onPressure: (Float) -> Void

  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.onPressure = onPressure
    return view
  }

  func updateUIView(_ uiView: ProbeView, context: Context) { uiView.onPressure = onPressure }

  final class ProbeView: UIView {
    var onPressure: ((Float) -> Void)?

    private func report(_ touches: Set<UITouch>) {
      guard let touch = touches.first(where: { $0.type == .pencil }), touch.maximumPossibleForce > 0
      else { return }
      onPressure?(Float(min(max(touch.force / touch.maximumPossibleForce, 0), 1)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onPressure?(0) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onPressure?(0) }
  }
}

extension Notification.Name {
  static let closeCompanionPanel = Notification.Name("Nib.closeCompanionPanel")
}
