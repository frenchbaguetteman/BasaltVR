# Quest hand tracking and Touch grip poses

Hand tracking is off by default; `basalt-streamer --hand-tracking on` turns it on. Then a Quest hand
that is not holding a controller drives an emulated Touch controller through gestures, and games get
the hand skeleton through `XR_EXT_hand_tracking`. OpenComposite uses that extension for OpenVR
skeletal input. Switching between hands and controllers works mid-session. When it is off, tracked
hands are ignored: a hand without a controller is untracked, and the runtime does not offer
`XR_EXT_hand_tracking`.

Verified on a Quest 3 in The Lab: hand tracking, gestures, and switching between hands and
controllers (see [compatibility](COMPATIBILITY.md)).

## Touch grip poses

The ALVR v20.14.1 client does not send Meta's grip pose. For Quest 2, 3, 3S, and Pro it sends the
grip multiplied by an offset meant for ALVR's own SteamVR driver: a 5 mm shift and a -15° pitch
about X (mirrored in x for the right hand). Passed through as the OpenXR grip, this offset was
stacked with OpenComposite's own Touch-to-SteamVR transform, so OpenVR games saw a tilted, shifted
hand. The streamer keeps the ALVR offset by default (`--grip-pose alvr`). `--grip-pose meta`
removes it, including the matching correction of linear velocity, so the runtime exposes Meta's
grip pose.

The aim pose still equals the grip pose because ALVR sends one pose per hand. OpenComposite
derives all OpenVR poses from grip, so this matters only for native OpenXR games that use aim.

## Data path

```
Quest (ALVR client 20.14.1)
  tracking packet: device motions + 26 hand joints per hand (XR_EXT_hand_tracking order,
  stage space, not predicted); about 1.7 KB with both hands, so 2 shards over Wi-Fi
        |
basalt-streamer: reassembles shards, decodes the packet, and decides per hand and per packet:
  controller:  grip = ALVR pose (ALVR offset removed only if opted in), client buttons, profile
  hand:        (hand tracking on) grip from the palm joint, gesture buttons, Touch profile,
               HAND_SKELETON
        |
control protocol v11: CONTROLLER_MOTION, BUTTON_STATE, INTERACTION_PROFILE, CONTROLLER_MASK,
                      HAND_SKELETON (26 joints of pose + radius, joint-valid mask)
        |
OpenXR runtime: oculus/touch_controller actions + XR_EXT_hand_tracking
        |
OpenComposite: skeletal input from xrLocateHandJointsEXT, buttons and poses from Touch actions
```

Nothing in the stream configuration turns hand tracking on. The ALVR client creates hand trackers
whenever the Quest runtime offers `XR_EXT_hand_tracking` and the ALVR app has the hand-tracking
permission. On the Quest, **Settings > Movement tracking > Hand and body tracking** must be on,
with automatic switching between hands and controllers.

## Gestures

A port of ALVR v20.14.1's `hand_gestures.rs` with ALVR's default thresholds (pinch at 2.5 mm
between joint surfaces, curl between 2.0 and 2.5 cm, 50 ms to activate, 100 ms to release,
100 ms before a released gesture can repeat):

| Gesture | Left hand | Right hand |
|---|---|---|
| Thumb + index pinch | trigger | trigger |
| Thumb + middle pinch | Y | B |
| Thumb + ring pinch | X | A |
| Thumb + little pinch | menu | — |
| Curl middle, ring, and little fingers (fist) | grip (squeeze) | grip (squeeze) |
| Thumb tucked onto the palm | thumbstick click | thumbstick click |
| Fist with the thumb on the side of the index finger | thumbstick x/y | thumbstick x/y |

The emulated grip pose is the palm joint rotated into OpenXR grip axes (+X out of the palm, -Z
from the little finger toward the thumb) and moved 2.5 cm to the palm side. Its velocity is zero,
as in ALVR.

When a hand becomes hand-tracked, all Touch inputs of that hand are released and then driven by
gestures; the client's button values for that hand are held back. When the controller comes back,
the skeleton is cleared and the client's latest values are restored. The interaction profile
stays Touch in both modes, so games keep their bindings and no profile-change event is needed.
The streamer log prints `left hand: Quest hand tracking (pinch = trigger, fist = grip)` or
`left hand: Touch controller` (and the same for the right hand) when a hand switches.

## Runtime

- `XR_EXT_hand_tracking` is advertised only when the control file lists the `hand_tracking`
  feature, which the streamer writes when hand tracking is on.
- `xrLocateHandJointsEXT` returns the latest skeleton younger than 500 ms in any base space the
  runtime can locate (LOCAL, STAGE, VIEW, action spaces), after the LOCAL recenter. Otherwise it
  returns `isActive = XR_FALSE` with `XR_SUCCESS`, because OpenComposite aborts on any error.
- Joint radii come from a typical-adult table in the streamer (ALVR sends none). Joint velocities
  are reported as unavailable.
- Hand trackers live until `xrDestroySession`; OpenComposite never destroys them first.

Control protocol v11 adds `HAND_SKELETON` (see
[the control protocol](DXMT-INTEROP.md#4-control-channel-and-message-protocol)). Like v9 and v10,
it is a breaking change: the bottle's runtime DLL and the streamer must come from the same build.

## Limitations

- Skeletons are not predicted (the client locates joints at its current time), so hands lag
  controllers by the pipeline latency.
- The pinch-to-trigger value is a step, as in ALVR.
- Tucking the thumb into the palm presses thumbstick click (ALVR's mapping). A game that uses
  stick click for something disruptive may need an option to turn this off; none exists yet.
- The aim pose of a hand equals its grip pose.

## Tests

- `swift test --package-path streamer --filter HandTrackingTests`: tracking-packet decode with
  skeletons, shard reassembly, ALVR offset removal, palm-to-grip axes per hand, each gesture,
  controller/hand switching, hand tracking off, the `HAND_SKELETON` layout, the control-file
  feature, and Touch path IDs against `runtime/pe/input.cpp`.
- `runtime/scripts/test-dxmt.zsh` (control-socket gate): the extension is advertised only with the
  feature, trackers are inactive before data, the palm matches the grip pose in LOCAL and STAGE,
  joint offsets and radii, grip-relative location, untracking, stale-sample rejection, validation
  errors, and tracker lifetime.
