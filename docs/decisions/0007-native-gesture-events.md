# 0007 — Native magnify and rotate gesture events

## Approach

Nib emits a `CGEvent` whose type is the private Quartz gesture type 29. The
event is posted at the HID event tap, with one event for each began, changed,
and ended phase. This is the same event shape used by WebKit's macOS event
sender ([source](https://chromium.googlesource.com/external/github.com/WebKit/webkit/+/e6f7d52fab9ee8141742193a5515b3463404a4f8/Tools/WebKitTestRunner/mac/EventSenderProxy.mm)).

## Fields

The raw field IDs are kept in `NativeGestureEventBuilder`:

- field 55 is the private event type and is set to 29 (`kCGSEventGesture`)
- field 110 is the HID subtype: 8 (`kIOHIDEventTypeZoom`) for magnify and 5
  (`kIOHIDEventTypeRotation`) for rotate
- field 113 carries magnification delta; field 114 carries rotation degrees
- field 132 carries phase: began 1, changed 2, ended 4, cancelled 8

The IDs are corroborated by WebKit's public test SPI header and the [cidre
CoreGraphics constants](https://docs.rs/cidre/latest/src/cidre/cg/event_types.rs.html).
The HID event type values come from the published [IOHID event type
header](https://github.com/alexandred/VoodooI2C-Rewrite/blob/master/Dependencies/Headers/IOKit/hid/IOHIDEventTypes.h).
Apple documents magnification as an incremental value and rotation as degrees
in its [trackpad event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html).

## Risks and fallback

These are private fields and are not guaranteed by Apple. A macOS update may
change their meaning or cause applications to ignore them. The CLI provides a
quick manual check, while profiles retain modifier-plus-scroll zoom as a
fallback. Native gesture events are always ended on disconnect to avoid
leaving an app in an active gesture state.
