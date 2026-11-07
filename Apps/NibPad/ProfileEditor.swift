import NibCore
import SwiftUI

/// Edits one profile in place. The profile is looked up by id on every access
/// so reordering or deleting profiles can never leave a stale index behind.
struct ProfileEditor: View {
  @Bindable var store: PadSettingsStore
  let profileID: UUID
  let frontApp: ControlMessage.FrontApp
  let hostInfo: ControlMessage.HostInfo?
  @Environment(\.dismiss) private var dismiss
  @State private var confirmsDelete = false

  private var isDefault: Bool { store.settings.isDefault(profileID) }

  private var profile: Binding<PadSettings.Profile> {
    Binding(
      get: {
        store.settings.profiles.first(where: { $0.id == profileID })
          ?? PadSettings.Profile(id: profileID, name: "")
      },
      set: { newValue in
        guard let index = store.settings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        store.settings.profiles[index] = newValue
      })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Name") { TextField("Profile name", text: profile.name) }
        if !isDefault { appsSection }
        buttonsSection
        stripSection
        gesturesSection
        if !isDefault {
          Section {
            Button("Delete profile", role: .destructive) { confirmsDelete = true }
          }
        }
      }
      .navigationTitle(profile.wrappedValue.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } } }
      .confirmationDialog("Delete this profile?", isPresented: $confirmsDelete, titleVisibility: .visible) {
        Button("Delete", role: .destructive) {
          store.settings.deleteProfile(id: profileID)
          dismiss()
        }
      }
    }
    .onAppear {
      if !supports(ControlMessage.Capability.zoomNative),
        profile.wrappedValue.gestures.zoomMethod == .nativeGesture
      {
        profile.wrappedValue.gestures.zoomMethod = .modifierScroll
      }
    }
    .preferredColorScheme(.dark)
  }

  /// Blank prefixes are dropped on close; they would otherwise be dead entries.
  private func finish() {
    profile.wrappedValue.appIDPrefixes.removeAll {
      $0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    dismiss()
  }

  // MARK: Apps

  private var appsSection: some View {
    Section {
      ForEach(profile.wrappedValue.appIDPrefixes.indices, id: \.self) { index in
        HStack {
          TextField("Bundle ID prefix", text: prefixBinding(index))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button(role: .destructive) {
            profile.wrappedValue.appIDPrefixes.remove(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
        }
      }
      Button("Add prefix") { profile.wrappedValue.appIDPrefixes.append("") }
        .buttonStyle(.borderless)
      Button("Use current front app (\(frontAppTitle))") {
        let id = frontApp.appID
        if !profile.wrappedValue.appIDPrefixes.contains(id) {
          profile.wrappedValue.appIDPrefixes.append(id)
        }
      }
      .buttonStyle(.borderless)
      .disabled(frontApp.appID.isEmpty)
    } header: {
      Text("Apps")
    } footer: {
      Text("This profile is used when the Mac's front app has a bundle ID starting with one of these.")
    }
  }

  private var frontAppTitle: String {
    frontApp.appID.isEmpty ? "none reported" : frontApp.name
  }

  private func prefixBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: {
        let prefixes = profile.wrappedValue.appIDPrefixes
        return prefixes.indices.contains(index) ? prefixes[index] : ""
      },
      set: {
        guard profile.wrappedValue.appIDPrefixes.indices.contains(index) else { return }
        profile.wrappedValue.appIDPrefixes[index] = $0
      })
  }

  // MARK: Buttons

  private var buttonsSection: some View {
    Section {
      ForEach(profile.wrappedValue.buttons.indices, id: \.self) { index in
        ButtonRow(
          button: buttonBinding(index),
          canMoveUp: index > 0,
          canMoveDown: index < profile.wrappedValue.buttons.count - 1,
          move: { profile.wrappedValue.moveButton(at: index, by: $0) },
          delete: { profile.wrappedValue.buttons.remove(at: index) },
          hideMeta: hostInfo?.platform == .macos)
      }
      Button("Add button") { profile.wrappedValue.addButton() }
        .buttonStyle(.borderless)
        .disabled(!profile.wrappedValue.canAddButton)
    } header: {
      Text("Buttons (\(profile.wrappedValue.buttons.count)/\(PadSettings.maxButtons))")
    } footer: {
      Text("Hold buttons press the key down while touched; others tap once.")
    }
  }

  private func buttonBinding(_ index: Int) -> Binding<PadSettings.ShortcutButton> {
    Binding(
      get: {
        let buttons = profile.wrappedValue.buttons
        return buttons.indices.contains(index) ? buttons[index] : .init(label: "", chord: .init())
      },
      set: {
        guard profile.wrappedValue.buttons.indices.contains(index) else { return }
        profile.wrappedValue.buttons[index] = $0
      })
  }

  // MARK: Strip and gestures

  private var stripSection: some View {
    Section("Strip") {
      Picker("Mode", selection: profile.strip.mode) {
        Text("Off").tag(PadSettings.StripMode.off)
        Text("Scroll").tag(PadSettings.StripMode.scroll)
        Text("Zoom").tag(PadSettings.StripMode.zoom)
        Text("Brush size").tag(PadSettings.StripMode.brushSize)
      }
      .pickerStyle(.segmented)
      Picker("Side", selection: profile.strip.side) {
        Text("Left").tag(PadSettings.StripSide.left)
        Text("Right").tag(PadSettings.StripSide.right)
      }
      .pickerStyle(.segmented)
      .disabled(profile.wrappedValue.strip.mode == .off)
    }
  }

  private var gesturesSection: some View {
    Section("Gestures") {
      Toggle("Two-finger scroll", isOn: profile.gestures.twoFingerScroll)
      Toggle("Pinch zoom", isOn: profile.gestures.pinchZoom)
      if supports(ControlMessage.Capability.zoomNative) {
        Picker("Zoom method", selection: profile.gestures.zoomMethod) {
          Text("Native trackpad").tag(PadSettings.ZoomMethod.nativeGesture)
          Text("Modifier + scroll").tag(PadSettings.ZoomMethod.modifierScroll)
        }
      }
      if supports(ControlMessage.Capability.rotateNative) {
        Toggle("Two-finger rotate", isOn: profile.gestures.rotate)
      }
      Picker("Zoom modifier", selection: profile.gestures.zoomModifier) {
        Text("⌘").tag(PadSettings.ZoomModifier.primary)
        Text("⌥").tag(PadSettings.ZoomModifier.alt)
        Text("⌃").tag(PadSettings.ZoomModifier.control)
      }
      .pickerStyle(.segmented)
      .disabled(profile.wrappedValue.gestures.zoomMethod == .nativeGesture)
      Toggle("Tap undo / redo", isOn: profile.gestures.tapUndoRedo)
    }
  }

  private func supports(_ capability: String) -> Bool {
    hostInfo?.capabilities.contains(capability) ?? false
  }
}

private struct ButtonRow: View {
  @Binding var button: PadSettings.ShortcutButton
  let canMoveUp: Bool
  let canMoveDown: Bool
  let move: (Int) -> Void
  let delete: () -> Void
  let hideMeta: Bool

  private static let modifiers: [(NibCore.Gesture.Modifier, String)] = [
    (.primary, "⌘ Primary"), (.control, "⌃ Control"), (.alt, "⌥ Alt"),
    (.shift, "⇧ Shift"), (.meta, "Meta"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        TextField("Label", text: $button.label)
        Button {
          move(-1)
        } label: {
          Image(systemName: "chevron.up")
        }
        .disabled(!canMoveUp)
        Button {
          move(1)
        } label: {
          Image(systemName: "chevron.down")
        }
        .disabled(!canMoveDown)
        Button(role: .destructive, action: delete) { Image(systemName: "trash") }
      }
      HStack {
        ForEach(Self.modifiers.filter { !(hideMeta && $0.0 == .meta) }, id: \.0) { modifier, symbol in
          Toggle(symbol, isOn: modifierBinding(modifier)).toggleStyle(.button)
        }
        Spacer()
        NavigationLink {
          KeyPicker(key: $button.chord.key)
        } label: {
          Text("Key: \(button.chord.key.flatMap(KeyNames.name(for:)) ?? "None")")
        }
        .fixedSize()
      }
      HStack {
        Toggle("Hold", isOn: $button.hold)
        Text(KeyNames.displayName(for: button.chord))
          .font(.body.monospaced()).foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 4)
  }

  private func modifierBinding(_ modifier: NibCore.Gesture.Modifier) -> Binding<Bool> {
    Binding(
      get: { button.chord.modifiers.contains(modifier) },
      set: {
        if $0 { button.chord.modifiers.insert(modifier) } else { button.chord.modifiers.remove(modifier) }
      })
  }
}

/// Keyboard-free key choice from the NibCore table.
private struct KeyPicker: View {
  @Binding var key: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Button {
          select(nil)
        } label: {
          Text("None (modifiers only)").frame(maxWidth: .infinity).padding(10)
        }
        .buttonStyle(.bordered)
        .tint(key == nil ? .cyan : .gray)
        ForEach(KeyNames.Group.allCases, id: \.self) { group in
          Text(group.rawValue).font(.headline)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
            ForEach(KeyNames.keys(in: group), id: \.code) { item in
              Button {
                select(item.code)
              } label: {
                Text(item.name).frame(maxWidth: .infinity).padding(.vertical, 10)
              }
              .buttonStyle(.bordered)
              .tint(self.key == item.code ? .cyan : .gray)
            }
          }
        }
      }
      .padding()
    }
    .navigationTitle("Key")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func select(_ code: String?) {
    key = code
    dismiss()
  }
}
