# Known issues and limitations

**Date:** 2026-09-18 (first written 2026-09-03)
**Status of the project:** the link works end to end - the Flipper screen is mirrored correctly on
the watch and button presses reach the Flipper. Everything below is what is *not* solved. Nothing
here is speculative: each entry names the evidence it rests on, and where a fix is unverified it
says so rather than implying it works.

Severity is about impact on a user who installs this, not about how hard it is to fix.

---

## Security

These are the entries that must be read before publishing. They are not bugs in the sense of
"something misbehaves" - the system does exactly what it was built to do. The point is that what it
does carries risk that a user has to be told about.

### S1 - With Open BLE Pairing on, any device in range gets full RPC access · **addressed 2026-09-18, unverified on hardware**

> **Update 2026-09-18.** Firmware commit `968af52` puts a prompt in front of RPC: GAP emits
> `GapEventTypeConnectionRequest` before `GapEventTypeConnected` on a Just Works link; the bt
> service answers from an allowlist in internal flash or asks on screen ("Allow BLE remote?" with
> the address, Deny/Allow). Deny terminates the link before any service is reachable. Momentum
> settings gain "Forget BLE Remotes". **Not yet run on a device.** The text below describes the
> state before that commit and remains accurate for stock Momentum and for anyone on the earlier
> patch.

When `open_ble_pairing` is enabled, `serial_profile.c` sets `bonding_mode = false` and
`pairing_method = GapPairingNone`, `gap.c` sets `MITM_PROTECTION_NOT_REQUIRED`, and
`serial_service.c` relaxes every serial characteristic to `ATTR_PERMISSION_NONE`. There is no PIN,
no bonding, and no on-device confirmation.

RPC is not a screen-sharing channel. It grants read/write access to the SD card filesystem,
application launching, and input injection. So: **any BLE central within radio range can take
control of the Flipper while the setting is on.**

This project's own firmware patch widens that surface deliberately: `gap.c` emits
`GapEventTypeConnected` immediately on connection for `GapPairingNone`, because otherwise the RPC
session is never opened and nothing works at all. That change is what makes the watch app possible
and is also what removes the last step an attacker would have had to clear.

Mitigating factor, and the reason this is shipped at all: the setting is **off by default**
(`lib/momentum/settings.c`: `.open_ble_pairing = false`) and has to be turned on deliberately.

Fix would be: a connection-confirmation prompt on the Flipper for unknown centrals (see S2).

### S2 - No confirmation on the Flipper when a new device connects · **addressed 2026-09-18, unverified on hardware**

> **Update 2026-09-18.** Implemented together with S1 (`968af52`). Remaining limitation: the
> allowlist matches on BLE address, so a central using resolvable private addresses is asked
> again when its address rotates. Whether a Garmin watch does this is not known yet - it is the
> first thing to observe on hardware.

Nothing on the Flipper asks the user to approve an incoming connection, and nothing distinguishes a
device that has connected before from one that never has. A connection is silent.

A confirmation screen for first-time centrals would close the worst case in S1 without needing
bonding, which Connect IQ cannot do anyway. This is also the change most likely to make the firmware
patch acceptable upstream in Momentum.

### S3 - The link is unencrypted · **high**

`GapPairingNone` with `MITM_PROTECTION_NOT_REQUIRED` and no bonding means no link-layer encryption
is established. Everything on the wire - screen contents, keystrokes - is readable by anyone
sniffing BLE nearby.

### S4 - No device allowlist on the Flipper side · **addressed 2026-09-18, unverified on hardware**

> **Update 2026-09-18.** `bt_open_pairing_allowlist.{c,h}` (`968af52`): up to 8 approved
> addresses in `/int/.bt_open_allow`, filled by the Allow button, cleared by "Forget BLE Remotes".

The Flipper accepts any central. It cannot be restricted to a known watch.

---

## Device selection and pairing

### P1 - The watch connects to the first Flipper it sees · **addressed 2026-09-18, unverified on hardware**

> **Update 2026-09-18.** Watch commit `40f26f4` adds a device picker fed live from the scan. Only
> the device chosen last time (Application.Storage) connects on its own; everything else goes
> through the list, Flippers first with RSSI, with an "other devices" expansion. ENTER while not
> connected opens the picker. A link that closes before anything arrived is treated as a Deny on
> the Flipper and does **not** reconnect, since each retry would re-prompt the Flipper's user.

`FlipperBleDelegate.onScanResults` stops scanning and connects on the first match:

```monkeyc
if (isFlipper) { Ble.setScanState(Ble.SCAN_STATE_OFF); _device = Ble.pairDevice(r); return; }
```

With two Flippers in range the result is whichever advertised first - non-deterministic, and it
cuts both ways: this watch may connect to someone else's Flipper, and someone else's watch may
connect to this one. There is no picker and no "remember the last device".

### P2 - A developer's device name is hardcoded · **addressed 2026-09-18, unverified on hardware**

> **Update 2026-09-18.** `KNOWN_NAMES` is gone (`40f26f4`). The risk noted below - that unit's
> name does not contain "Flipper" - is covered by the picker's "other devices" list rather than by
> a name list. Whether the UUID/appearance heuristics still find that unit on their own is the
> second thing to observe on hardware.

```monkeyc
const KNOWN_NAMES = ["Fa14f31"];
```

This is one specific Flipper. Worse, it may be load-bearing: that unit advertises as `Fa14f31`,
which does **not** contain the string "Flipper", so the generic name test does not match it. The
other detection paths (advertised UUID `0x3080`-`0x3083`, GAP appearance `0x8600`, raw advertising
payload) should cover it, but **this has not been verified with the name list removed**. Removing it
blind risks breaking the one configuration known to work.

---

## Compatibility

### C1 - One watch model is supported · **addressed 2026-09-18 (118 models build), untested beyond Descent Mk2**

> **Update 2026-09-18, later.** Device files downloaded via the SDK Manager (after repairing it -
> see the journal). `tools/build-all-devices.sh` now selects every installed device with Connect IQ
> ≥ 3.2 and a watch-app memory limit ≥ 512 KB, and builds one `.prg` each: 118 models (the SDK Manager kept downloading while the script ran), fenix 5 Plus
> through fenix 9, epix, MARQ, Venu, vívoactive 3 Music-6, Descent Mk2, Forerunner, Instinct 3, Edge, Approach and a few handhelds. Six
> models with a 128 KB limit (fenix 6/6S non-Pro, Instinct, Venu Sq) are excluded on purpose: the
> app is ~140 KB and would die on launch. Touchscreen models get swipe = direction, tap = OK.
> **Only the Descent Mk2 has ever run it.** The watchdog budget (R2) and the launcher icon (one
> 40×40 asset scaled by the device) are unverified everywhere else.
>
> Earlier that day: Building for another model needs that
> model's device files from the Connect IQ SDK Manager, which is a login-gated GUI with no CLI
> (`sdkmanager -h` offers only `-u`). Only `descentmk2` is present locally. The target list and
> the watchdog-budget caveat below stand; the manifest change itself is a few lines once the
> files exist.

`manifest.xml` declares exactly one product: `descentmk2`. No other Garmin can install the app.

The natural next set is the 5-button family (fenix 6/7/8, epix, Forerunner 255/955/965,
Descent Mk2/Mk3) where the key mapping carries over unchanged. Each still needs a build and a
watchdog-budget check, because they differ in CPU and this app runs close to that limit (see R2).

### C2 - Requires patched Momentum firmware · **high**

Stock Momentum will not work. The changes in `gap.c`, `bt.c`, `serial_service.c` and
`serial_profile.c` are not upstream. Until a PR is accepted, every user has to build and flash
firmware themselves.

### C3 - Tested on exactly one pair of devices · **medium**

One Descent Mk2 and one Flipper. No evidence about any other combination.

---

## Performance

### F1 - About 0.5 frames per second · **high**

Measured on the Flipper, 2026-09-03:

```
Connection Interval: 6 (7 ms)      <- optimal, renegotiated down from 997 ms
MTU exchange request failed: 1     <- MTU stayed at the 23-byte default
TXMSG 1038 mps=20                  <- 1038-byte frame in 20-byte packets = 52 packets
```

The connection interval is already as good as it gets; the earlier 997 ms imposed by the watch is
renegotiated to 7 ms in one round. The bottleneck is entirely MTU: a frame costs 52 packets instead
of the ~5 it would cost at MTU 247, and each packet waits for its own INDICATE confirmation
(`bt_rpc_send_bytes_callback` blocks on `furi_event_flag_wait` per packet). Measured round trip is
~38 ms per packet, several connection intervals, because Connect IQ has to push each indication
through the app before confirming.

### F2 - The MTU retry is unverified · **high**

A retry of `aci_gatt_exchange_config` on `HCI_LE_CONNECTION_UPDATE_COMPLETE` was added, on the
theory that the original attempt at connection time is too early (status 1 = failed). **It has not
been confirmed to work.** Three capture attempts produced empty logs: the first two because stale
background processes were holding `/dev/ttyACM0` and stealing the bytes, the third because the
capture window closed before the app connected.

Until one clean capture shows either `Rx MTU size:` with a real value or another failure, whether
Connect IQ can raise the MTU at all is **unknown**. This is the single highest-value open question
for performance - the difference between 52 and 5 packets per frame.

### F3 - INDICATE serialises the transfer · **medium**, deliberate

ATT permits one outstanding indication at a time, so throughput is capped at one packet per round
trip regardless of MTU. Switching the serial characteristic to NOTIFY would allow several packets
per connection interval and is the largest remaining lever.

It has been deliberately left alone. RPC is a byte stream framed by varint length prefixes, so a
single lost packet does not corrupt one frame - it desynchronises the framing permanently. INDICATE
is what bought the correct image after a long debugging effort. This should only be revisited with
measurements in hand and a resynchronisation strategy.

### F4 - Keypress latency of seconds · **medium**

Input is queued ahead of frame data, but a keypress still waits behind whatever packets are in
flight. The on-screen pending-key strip exists to make this legible rather than to fix it.

---

## Stability

### R1 - The Flipper hung once, unexplained · **high**

During testing on 2026-09-03 the Flipper locked up on a spinning hourglass for several minutes and
needed a hard reset. It happened after returning from the Garmin Wallet screen. **No logs were
captured, and it has not been reproduced.** The cause is unknown; a plausible but unproven direction
is RPC/GUI stream load. Flagged rather than explained.

### R2 - The render is close to the watchdog limit · **medium**

> **Update 2026-09-18.** `simulator.json` exposes the budget: 240 000 on most watches, **120 000 on
> the Forerunner 255 family**, 2 500 000 on Edge. The render now uses 8 slices of ≤300 rectangles
> instead of 4 of ≤600 - same frame capacity, half the work per update. Per-device table in
> [`COMPATIBILITY.md`](COMPATIBILITY.md).

Connect IQ kills the app if a single `onUpdate` runs too long ("Watchdog Tripped"). Confirmed the
hard way on 2026-09-03: drawing a whole frame in one pass at 2400 rectangles crashed repeatedly
(`CIQ_LOG.YML`, `Framebuffer.draw` <- `onUpdate`). The frame is now split into 4 slices of 16 rows
with a 600-rectangle cap per slice.

600 per slice is an empirical value, not a computed one. It holds on a Descent Mk2 and may not hold
on a slower device (see C1).

### R4 - Round screens cut the image corners · **accepted, by decision 2026-09-18**

The integer fit places the image's corners outside the round bezel on 54 of 118 models (3 px per
side on the 280 px Mk2, 15 px on 260 px, 22 px on 390 px). A circle-bounded fractional scale was
built and tried on the Mk2; the user preferred the larger image - the Flipper draws nothing in its
extreme corners - so the integer fit stays. On 260 px and 390 px screens the loss is larger and
**unverified**; revisit with one of those in hand. Layout per screen in
[`COMPATIBILITY.md`](COMPATIBILITY.md) (its scale column reflects the fractional variant).

### R3 - A very dense screen would be truncated · **low**

Capacity is 4 slices x 600 = 2400 rectangles per frame. A text-heavy Flipper screen costs roughly
1300, so there is headroom, but a pathological screen (fine dithering, a checkerboard) would exceed
it and the remainder of the frame would simply not be drawn. No visible indication would be given.

---

## User interface

### U1 - The backlight latch does not hold · **low**

A short LIGHT press calls `Attention.backlight(true)`, but on current Garmin firmware that only
lights the screen for the system timeout; there is no API for a permanent backlight. It could be
kept alive by re-triggering on a timer, which has not been done.

### U2 - Button holds belong to the system, not the app · **low**, not fixable

Garmin claims held buttons as system hotkeys before a Connect IQ app sees them - hold ENTER opens
Wallet, hold LIGHT opens the controls menu - even though the app consumes the key events. This is
why the axis toggle is a double tap of ENTER rather than a hold. There is no way around it from
inside the app; it constrains what gestures can ever be offered.

### U3 - Long-press OK cannot reach the Flipper · **low**

ENTER is held back for 350 ms to distinguish a single tap from the double tap that flips the axis,
so a Flipper long-OK is not expressible. Direction keys and BACK still send long presses.

---

## Instrumentation

### I1 - Serial captures are fragile · **low**

Three speed measurements were lost to a foreseeable cause: background log readers from earlier
sessions kept `/dev/ttyACM0` open, and two readers on one port split the stream so both get
useless fragments. Always confirm the port has no other holder (`fuser /dev/ttyACM0`) before
trusting an empty capture as evidence of silence.

---

## Recommended order

1. **Verify on hardware** what 2026-09-18 added blind: the approval prompt (S1/S2), the picker and
   remembered device (P1/P2), and whether the Garmin's address is stable across connections.
2. **C1** - download device files via the SDK Manager GUI, add the 5-button family to the
   manifest, build each, check the **R2** budget where a device can be borrowed.
3. **F2** - one clean capture to settle the MTU question, which either closes performance or
   opens the NOTIFY discussion (**F3**).
4. **C2** - upstream the firmware patch; the approval prompt is the argument for it. Draft in
   [`UPSTREAM-PR.md`](UPSTREAM-PR.md).
