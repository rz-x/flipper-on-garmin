# Flipper Watch Remote - project journal

**Period covered:** 2026-08-20 to 2026-09-18
**Outcome:** working. The Flipper Zero's 128x64 screen is mirrored on a Garmin Descent Mk2 over BLE,
and the watch's buttons drive the Flipper. Refresh is ~0.5 frames per second.

This document is the project's memory: what was built, what broke, how each cause was actually
found, and what remains. It is written to be useful three ways - as development notes, as project
documentation, and as raw material for a longer write-up. Where something is unproven it is marked
unproven; the failures are recorded as carefully as the successes, because on this project the
failures were where all the information was.

Known issues have their own register: [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md). The feasibility analysis
that started it is [`spike-0-findings.md`](spike-0-findings.md).

---

## 1. What this is

A Garmin watch app that mirrors the Flipper Zero's screen and relays keypresses, so the Flipper can
be operated from the wrist while it stays in a pocket or bag - whatever app it happens to be
running, because the mirror is of the framebuffer, not of any particular application.

Two devices, two codebases:

- **Watch app** (Monkey C / Connect IQ) - BLE central, protobuf RPC client, framebuffer renderer.
- **Momentum firmware patch** (C) - makes the Flipper's existing RPC reachable by a central that
  cannot bond.

The starting question was not "how do we build this" but "can this work at all". Roughly thirty
rounds of attempts had already failed before the work in this journal began, with no image and no
diagnosis.

---

## 2. The structural problem, established before any code

Connect IQ's BLE stack **cannot bond**. It has no SMP, so it can never establish an authenticated,
encrypted link. Momentum's stock serial/RPC characteristics require exactly that:

```c
// serial_service.c (stock)
ATTR_PERMISSION_AUTHEN_READ | ATTR_PERMISSION_AUTHEN_WRITE
// serial_profile.c (stock)
.pairing_method = GapPairingPinCodeShow    // -> MITM_PROTECTION_REQUIRED
```

So the watch could not reach the Flipper's RPC no matter how the app was written. This was the
feasibility gate, and it came out as "blocked without a firmware change".

The decision at that point shaped everything after: **do not build a bridge, open the existing
path.** A phone-side or PC-side relay would have worked and would have been easy, but it would have
made the product useless - the whole point is a watch and a Flipper, with nothing in between. The
alternative was a small opt-in firmware toggle that drops the serial profile to Just Works with no
bonding. That is what was built.

This is also the root of the security posture recorded in `KNOWN-ISSUES.md` §S1: the feature exists
precisely because it removes an authentication requirement.

---

## 3. Chronology of causes

The link failed for **eight independent reasons**, in series. Each one produced the same symptom
from the outside - nothing on the watch screen - which is why it resisted diagnosis for so long.
Every fix revealed the next fault rather than producing a result.

### 3.1 UUIDs were byte-reversed

`serial_service_uuid.inc` lists UUID bytes in **little-endian** order. They had been copied
literally into the watch app, which needs over-the-air (big-endian) form. The app was scanning for
a service that did not exist.

### 3.2 Connect IQ only surfaces advertisers with 16-bit UUIDs

Connect IQ never showed the Flipper in scan results even with correct UUIDs. Its scanner parses
only `ADV_IND` - never the scan response - and it keys on 16-bit service UUIDs. The Flipper's
128-bit service is invisible to it; the `0x3080`-family 16-bit UUID is what it can actually see.

At one point the `0x3080` advertising UUID was *removed* on the theory that it was noise. That was
wrong and it was reverted: Connect IQ needs it. Recorded here because the mistake cost a round of
testing and the reasoning that produced it was plausible.

### 3.3 Advertising was too slow

The Flipper advertised at 1-2.5 s intervals, slow enough that Connect IQ's scan window kept missing
it. Forced to the fast interval when `open_ble_pairing` is on.

### 3.4 The watch's BLE stack wedged

After many failed connection attempts the watch stopped scanning usefully at all. Cleared by
forgetting the pairing and rebooting the watch. Worth knowing because it masquerades as a code bug
and wasted a testing round: **when results stop making sense on the watch, reboot it before
believing the data.**

### 3.5 `GapEventTypeConnected` was never emitted without pairing

The first genuinely deep one. GATT connected, but the RPC session never opened - the app reported
`rpcCh=0` and every RPC request went unanswered.

Cause: the bt service opens the RPC session on `GapEventTypeConnected`, which `gap.c` emitted only
from `ACI_GAP_PAIRING_COMPLETE`. With `GapPairingNone` there is no pairing, so that event never
fires and the session was never created. Fixed by emitting it on `HCI_LE_CONNECTION_COMPLETE` when
the pairing method is `GapPairingNone`.

### 3.6 Writes used the wrong write type

Connect IQ's default is **write without response**. With no acknowledgement the app's transmit
queue never drained and wedged after the first write. Fixed with an explicit
`Ble.WRITE_TYPE_WITH_RESPONSE`.

### 3.7 The render watchdog killed the app

With data finally flowing, the app started crashing to the Connect IQ error screen a few seconds
after connecting. Connect IQ terminates an app whose `onUpdate` runs too long.

Confirmed - not guessed - from `CIQ_LOG.YML` on the watch, which carries a real stack trace:

```
Error: 'Watchdog Tripped Error - Code Executed Too Long'
Stack:
  - File: source/Framebuffer.mc     Line: 65   Function: draw
  - File: source/FlipperRemoteView.mc Line: 63 Function: onUpdate
```

Addressed by inlining the per-pixel bit test (a method call per pixel was itself too slow), capping
rectangles per pass, and splitting the frame across several `onUpdate` calls.

### 3.8 The breakthrough: MTU truncation

With everything above fixed the image appeared - and was garbage. Diagonal artefacts, shifted
blocks, gradually becoming more structured as other bugs were fixed but never correct.

The cause was a mismatch between what the firmware *thought* it could send and what the link would
carry:

```c
bt->max_packet_size = BLE_PROFILE_SERIAL_PACKET_SIZE_MAX;   // 486
```

The ATT default MTU is 23, i.e. **20 usable bytes**. The Flipper chunked each frame by 486 bytes and
advanced its send pointer by 486 - but only 20 bytes actually went out per packet. The remaining
466 were silently dropped, and the receiver reassembled a stream with periodic holes. Hence an image
that was almost right and never right.

It was found by adding one log line to the send path:

```c
FURI_LOG_I(TAG, "TXMSG %u mps=%u", (unsigned)bytes_len, (unsigned)bt->max_packet_size);
```

which printed `TXMSG 1038 mps=486` against a 20-byte MTU, and the whole thing collapsed in one
reading.

**This is the most instructive failure in the project, and it is a failure of method, not of
knowledge.** That hypothesis had already been formed, and those exact firmware lines had already
been read. It was dismissed on the strength of a cumulative received-bytes counter that looked
healthy - a counter that measured how much arrived, not whether it was contiguous, and therefore
could not have distinguished the two cases. A correct hypothesis was discarded using evidence that
had no bearing on it.

The user's intervention was the turning point: *"you have the firmware source in front of you, and
you still can't work out how RPC transmits?"* The fix was to stop reasoning about the code and
instrument it.

Fixed by clamping to the real MTU while open pairing is on, and raising it if a larger MTU is ever
negotiated:

```c
bt->max_packet_size = momentum_settings.open_ble_pairing ? 20 : BLE_PROFILE_SERIAL_PACKET_SIZE_MAX;
```

After this: **a correct mirror.** Roughly 60 seconds per frame.

---

## 4. Making it usable

A correct image at one frame per minute is a demo, not a product. The second phase was almost
entirely about latency and interaction.

### 4.1 Connection interval - 60 s to ~3 s

The Flipper renegotiates the connection interval when the central proposes something unsuitable,
but the check was gated behind `gap->is_secure`, which is only ever set from
`ACI_GAP_SLAVE_SECURITY_INITIATED` - i.e. only when pairing happens. On a Just Works link it was
therefore never evaluated, and the watch's proposal stood unchallenged.

The watch proposed **997 ms**. Every packet waited a full second.

```c
if(gap->is_secure || gap->config->pairing_method == GapPairingNone) {
    negotiation_failed |= connection_interval_max < gap->connection_params.conn_interval;
}
```

Measured afterwards:

```
Connection parameters: Connection Interval: 798 (997 ms)
Connection interval doesn't suite us. Trying to negotiate, round 1
Connection parameters: Connection Interval: 6 (7 ms)
Connection interval suits us. Spent 1 rounds to negotiate
```

997 ms to 7 ms. **Response time went from ~60 s to ~3 s** - the single largest improvement in the
project, and it came from a one-line condition.

### 4.2 MTU - the remaining bottleneck, unresolved

With the interval optimal, the measurement points at one thing:

```
MTU exchange request failed: 1
TXMSG 1038 mps=20            -> 1038 bytes / 20 = 52 packets per frame
```

Each packet waits for its own INDICATE confirmation (`bt_rpc_send_bytes_callback` blocks on
`furi_event_flag_wait` per packet), measured at ~38 ms per round trip because Connect IQ pushes each
indication through the app before confirming. At MTU 247 a frame would be ~5 packets instead of 52.

`aci_gatt_exchange_config()` was added at connection time and returns status 1. A retry at
`HCI_LE_CONNECTION_UPDATE_COMPLETE` - when the link has settled - has been implemented but **is not
verified** (`KNOWN-ISSUES.md` §F2). Whether Connect IQ will raise the MTU at all is still an open
question, and it is the most valuable one left.

### 4.3 Rendering - three iterations, one self-inflicted

The renderer went through three designs, and the middle one was a mistake worth recording.

**Two passes.** Top half in one `onUpdate`, bottom half in the next, to stay under the watchdog.
Symptom: half the screen froze. Cause: a newly arrived frame reset the pass counter mid-render, so
the lower half of the frame being drawn was never painted.

**One pass** (wrong). The pass counter was removed and the whole frame drawn in a single update with
the rectangle cap raised from 600 to 2400. This fixed the freeze and reintroduced the watchdog
crash, three times in a row, at exactly the line predicted before flashing. The lesson: the
diagnosis was right and the remedy bought correctness with a resource that had already been proven
scarce.

**Four slices with double buffering** (current). The real cause of the freeze was never the number
of passes - it was that a new frame could disturb one being drawn. So the frame being rendered is
now immutable and a frame arriving mid-render waits in `_pendingFrame`:

```monkeyc
if (_frame == null || _pass >= PASSES) { _frame = bytes; _pendingFrame = null; _pass = 0; }
else { _pendingFrame = bytes; }
```

Per-update cost returned to the proven 600 rectangles, while whole-frame capacity rose to 4 x 600.

**Then flicker, from the clear.** The first slice cleared the *whole* screen but painted only rows
0-16, so the lower three quarters sat blank until later updates. The user's description was precise
enough to identify it outright - "top third steady, lower two thirds blink once a second" - and the
fix was to erase only the band being painted, so no region is ever momentarily empty.

### 4.4 Input - the platform fights back

Six Flipper inputs (up/down/left/right/OK/back) must come from five physical buttons, and Garmin
reserves some of them.

**BACK exited the app.** Garmin closes a Connect IQ app on BACK at system level. Intercepted with
`BehaviorDelegate.onBack()` returning `true`; a short BACK now reaches the Flipper and a ~1.5 s hold
exits, matching Flipper convention.

**Left/right needed an axis toggle**, and finding a gesture for it took three attempts:

1. **LIGHT** - appears to be claimed by the system for the backlight. Never observed working.
2. **`onMenu()`** - cannot work, and this was caught by reasoning rather than by testing: Garmin
   only generates a behavior when the key events were *not* consumed, and `onKeyPressed` consumes
   everything.
3. **Hold ENTER** - opens **Garmin Wallet**. The user discovered this, and it is the most
   generalisable finding of the three: **Garmin claims button holds as system hotkeys before the app
   sees them, even when the app consumes the key events.** That invalidates holds as an interaction
   channel entirely, including the fallback plan of long-press UP/DOWN.
4. **Double tap of ENTER** - works. Short presses are the only gestures reliably delivered. A single
   ENTER is held back 350 ms so a second tap can cancel it, which is invisible against a ~3 s frame.

Because guessing which buttons are delivered had already cost several rounds, the app now displays
the **raw key code** of any unmapped key, turning the question into an observation.

---

## 5. Testing infrastructure

The project's real inflection point was not a fix, it was the moment testing stopped requiring the
user to reload, read the watch screen, and transcribe values by hand. Everything below exists to
gather evidence without a human in the loop.

| Purpose | Mechanism |
|---|---|
| Flipper runtime logs | CLI over `/dev/ttyACM0`, `log info` |
| Watch crash traces | `CIQ_LOG.YML` over MTP - real stack traces with file and line |
| Watch app install | `gio copy` to `mtp://.../Primary/GARMIN/Apps/` |
| Firmware flash | `./fbt flash_usb_full` |
| Decoder tests | Python port of the framebuffer decoder, runs with no hardware |

Two hard-won operational notes:

**Serial port contention.** Three separate speed measurements were lost because background log
readers from earlier sessions still held `/dev/ttyACM0`. Two readers on one port split the byte
stream and both get fragments - the capture looks like silence, which reads as "nothing happened".
Check `fuser /dev/ttyACM0` before treating an empty capture as evidence.

**The MTP mount drops** across Flipper and watch reboots, and the device re-enumerates with a new
USB device number. Remount rather than concluding the device is gone.

---

## 6. What was decided, and what was deliberately not done

**Not building a bridge app.** A phone or PC relay would have avoided the firmware work entirely and
would have destroyed the product's reason to exist.

**Not switching INDICATE to NOTIFY.** This is the largest remaining performance lever - notifications
need no per-packet confirmation, so many could be sent per connection interval. It is deliberately
untouched. RPC is a byte stream framed by varint length prefixes: a lost packet does not corrupt one
frame, it **desynchronises the framing permanently**. INDICATE is what bought a correct image after
a very long fight. It should only be revisited with measurements in hand and a resynchronisation
strategy, and only if MTU turns out to be a dead end.

**Not sending partial frame updates.** Transmitting only changed regions would cut traffic
dramatically, but it means a new protocol message. That is a much harder thing to get accepted
upstream in Momentum, and upstreaming is what removes the build-it-yourself barrier for users.

**Keeping the frame-rate readout.** The status bar was trimmed to a single `f/s` figure rather than
removed, because it is the instrument the speed work is measured against. It should go once tuning
is finished.

---

## 7. What will be hard

**Connect IQ's BLE ceiling.** No bonding, no MTU API, no connection-priority control, at most three
services, ~20-byte reads, only `ADV_IND` parsed, and a render watchdog that kills the app. Most of
this project's difficulty is this list. Several problems can only be attacked from the *firmware*
side because the watch side has no API for them - the connection interval fix is the model:
unfixable from the watch, one line in the firmware.

**Security without bonding.** Bonding is impossible on this platform, so link-layer authentication
is off the table by construction. The only workable protection is an application-level confirmation
on the Flipper (`KNOWN-ISSUES.md` §S2). This must be solved before publication: as it stands,
enabling the setting exposes full RPC - filesystem read/write, app launching, input injection - to
any device in radio range.

**Upstreaming.** The patch touches `gap.c`, `bt.c`, `serial_service.c` and `serial_profile.c` and
relaxes a security property. Acceptance is much more likely with a confirmation prompt included, and
that is the main argument for doing §S2 first rather than last.

**Multi-device support.** The 5-button family should port with no key-mapping changes, but each
model needs a build and a **watchdog budget check**. The 600-rectangles-per-slice figure is
empirical, established on a Descent Mk2, and there is no reason to assume it holds on slower
hardware.

**One unexplained hang.** The Flipper locked up once and needed a hard reset. No logs, not
reproduced, cause unknown. Recorded rather than explained.

---

## 8. Where things stand

Working: device discovery, connection without bonding, RPC session, correct full-screen mirror, all
six directions, short and long presses, hold-to-exit, backlight key, monochrome UI with a keypress
queue and a frame-rate readout, Momentum dolphin icon.

Measured: connection interval 7 ms (optimal), MTU 23 (**the bottleneck**), 52 packets per frame,
~0.5 frames per second.

Open, in the order recommended in `KNOWN-ISSUES.md`: connection confirmation on the Flipper, a
device picker on the watch, one clean MTU measurement, more watch models, and the upstream PR.

The single most valuable next action is the cheapest one: **one clean serial capture** to find out
whether the MTU retry works. It decides whether performance is finished or whether the NOTIFY
question has to be reopened.

---

## 9. Addendum, 2026-09-18 - security and selection, written without hardware

Two weeks later, with neither device to hand, the two publication blockers were implemented
blind. Both build; neither has run. That is a deliberate trade: the code exists and is reviewable,
and the first session with hardware is a verification session rather than a design one.

### 9.1 The Flipper now asks

The structural problem from §2 has no in-protocol answer - Connect IQ cannot bond, so the link can
never authenticate. What it can do is defer to a human. GAP emits a new
`GapEventTypeConnectionRequest` carrying the peer address *before* `GapEventTypeConnected`; the bt
service answers it from an allowlist in internal flash, or by putting a dialog on the Flipper:

```
        Allow BLE remote?
   Unknown device wants
   to control this Flipper
   C4:5B:...:1E
 [Deny]              [Allow]
```

Allow stores the address; Deny makes GAP terminate the link, so RPC is never reachable by a
refused peer. The handler blocks the GAP thread on the dialog - which sounds alarming until one
notices the stock numeric-comparison pairing handler does exactly the same, so the pattern is
already accepted in this codebase. "Forget BLE Remotes" in Momentum's settings clears the list.

The known weak point is address matching. If the watch uses resolvable private addresses, it
will be asked again after each rotation. Nothing found in documentation settles whether a Garmin
does; it is the first thing to look at with hardware.

### 9.2 The watch now asks too

The picker replaces "first match wins". The only device that connects unprompted is the one chosen
last time, kept in `Application.Storage`; a lone Flipper on first use still goes through the list,
because the point is that the user always knows which device they are about to take control of.
The hardcoded `Fa14f31` is gone, and the fallback for a Flipper with an unrecognisable name is a
human looking at an "all devices" list rather than a developer's name in the source.

Two interactions between the two sides had to be designed rather than discovered, since there was
no hardware to discover them on:

- **While the Flipper's dialog is up, the link is connected but RPC is closed.** Anything the
  watch sends is dropped. The RPC-status characteristic reads 0 for exactly that window, so the
  watch polls it every two seconds for up to ninety and shows "waiting for approval on the
  Flipper" instead of spending its ping budget into a void.
- **A Deny looks, from the watch, like a disconnect with nothing received.** The old behaviour
  was to reconnect after 1.5 s - which would put the dialog straight back on the Flipper, forever.
  Such a disconnect now stops the reconnect loop and hands the decision back to the user.

### 9.3 More watch models: blocked on a GUI

Adding models is a manifest change plus a build per device. The build needs each device's
definition files, which only the Connect IQ SDK Manager downloads, behind a Garmin login, with no
command-line mode (`sdkmanager -h` lists exactly `-u`). Only `descentmk2` is present locally.
Attempting the update flag headless simply opened the GUI on the user's desktop. Recorded as
blocked rather than worked around: the files are a human's download away, and driving a login
GUI from a script is the wrong kind of clever.

### 9.4 Later the same day: the SDK Manager, repaired

The blocker in §9.3 turned out to be a broken tool rather than a missing one. The SDK Manager
AppImage opened with a blank page after Login and then froze the X server. Cause, from its own log:
it bundles `libwebkit2gtk-4.0` but not WebKit's helper processes, and someone had binary-patched the
library to spawn the host's 4.1 helpers - a different IPC protocol, so the web process died and the
UI process aborted while holding an X grab. Release builds of WebKitGTK ignore `WEBKIT_EXEC_PATH`,
so the fix is the same trick done right: a matching WebKitGTK 2.50.4 from Ubuntu jammy (the base
the bundle was built on) copied into the bundle, its compiled-in helper path patched to a directory
of identical length under the user's home, and jammy's `glib-networking` for TLS, since the bundled
GLib 2.72 cannot load the host's newer GIO modules. The login page rendered; devices downloaded.

With device files in hand, "more models" became one script run: 118 builds, all successful. Touch
input (swipe = direction, tap = OK) was added for the two-button vívoactive/Venu family, and six
128 KB-memory models were excluded because the ~140 KB app cannot fit. None of the 117 new targets
has run on hardware.
