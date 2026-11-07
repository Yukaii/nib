import Testing

@testable import NibCore

@Test func capabilityFallbackKeepsChoiceUntilHostIsKnown() {
  let native = PadSettings.ZoomMethod.nativeGesture
  let capable = ControlMessage.HostInfo(
    platform: .macos, name: "Mac", appVersion: "1",
    capabilities: [ControlMessage.Capability.zoomNative, ControlMessage.Capability.rotateNative])
  let limited = ControlMessage.HostInfo(platform: .linux, name: "Linux", appVersion: "1", capabilities: [])
  #expect(GestureCapabilityPolicy.zoomMethod(native, host: nil) == .nativeGesture)
  #expect(GestureCapabilityPolicy.zoomMethod(native, host: capable) == .nativeGesture)
  #expect(GestureCapabilityPolicy.zoomMethod(native, host: limited) == .modifierScroll)
  #expect(GestureCapabilityPolicy.rotateEnabled(true, host: nil))
  #expect(GestureCapabilityPolicy.rotateEnabled(true, host: capable))
  #expect(!GestureCapabilityPolicy.rotateEnabled(true, host: limited))
}

@Test func hostPlatformHasUserFacingName() {
  #expect(HostPlatform.macos.displayName == "macOS")
  #expect(HostPlatform.windows.displayName == "Windows")
  #expect(HostPlatform.linux.displayName == "Linux")
}
