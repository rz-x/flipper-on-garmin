# Spike 0 - Feasibility gate findings

**Date:** 2026-08-20
**Hardware:** Garmin Descent Mk2 (Connect IQ, BLE central) + Flipper Zero on **Momentum** firmware.
**Method:** desk analysis of Momentum firmware source (`Next-Flip/Momentum-Firmware`, shallow clone). Hardware BLE test still outstanding (see §Remaining).

## Gate verdict: Outcome B - direct link blocked, Flipper-side firmware change required

Connect IQ cannot reach the Flipper's stock BLE serial/RPC stack directly.

### Evidence

- `targets/f7/ble_glue/services/serial_service.c`: RX and TX characteristics carry
  `ATTR_PERMISSION_AUTHEN_READ | ATTR_PERMISSION_AUTHEN_WRITE` - require a bonded, MITM-protected link.
- `targets/f7/ble_glue/profiles/serial_profile.c`: `.pairing_method = GapPairingPinCodeShow`.
  `gap.c` sets `MITM_PROTECTION_REQUIRED` for that method; only `GapPairingNone` ("just works")
  drops to `MITM_PROTECTION_NOT_REQUIRED`, and serial does not use it.
- Connect IQ BLE has no SMP bonding. Descent Mk2 exposes `Toybox.BluetoothLowEnergy`
  (BLE central confirmed available), so the block is the auth requirement, not BLE availability.
- Verified UUIDs. **ERRATUM (2026-08-31):** `serial_service_uuid.inc` lists UUID bytes
  LITTLE-ENDIAN (STM32WB ACI convention); the over-the-air UUIDs are the byte-reversed form.
  The values originally recorded here (`0000fe60-cc7a-...`) were the raw source-order bytes and
  are WRONG on the wire - they made the watch app's `getService()` return null on every connect.
  Correct central-side values (confirmed against working BLE clients, e.g.
  flipper-zero-bluetooth-serial-poc):
  - Service `8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000`
  - RX (write, host→Flipper) `19ed82ae-ed21-4c9d-4145-228e62fe0000`
  - TX (indicate, Flipper→host) `19ed82ae-ed21-4c9d-4145-228e61fe0000`
  - Flow control `...63fe0000`, RPC status `...64fe0000`
  Note: TX uses `CHAR_PROP_INDICATE` (not notify) - the Connect IQ profile must subscribe for indications.

## Deep blocker: the Flipper-side component cannot be a loadable FAP

Flipper runs one foreground app at a time. `loader.c` keeps a single `loader->app` slot and joins the
app thread on the next launch (`furi_thread_join(loader->app.thread)`). Therefore:

- While a mirror FAP runs, no other app (Sub-GHz, NFC, ...) runs - nothing to mirror.
- Launching another app tears the FAP down, killing its BLE service and bridge.

Persistent background code on Flipper must be `SERVICE`/`SYSTEM`/`STARTUP` app type - compiled into the
firmware image, started at boot (RPC itself is `STARTUP`). These are not installable `.fap` files.

**Consequence:** the Flipper-side deliverable is a custom Momentum firmware build the user must flash,
not a FAP. This is a heavier distribution story than a sideloaded app.

## What already works from background (no new bridge needed)

The stock RPC Gui service already does both directions we need, from its own service thread,
app-agnostically:
- Screen out: `gui_add_framebuffer_callback` → full composited 128×64 buffer of whatever is foreground
  (`rpc_gui.c:rpc_system_gui_start_screen_stream_process`).
- Input in: `furi_pubsub_publish(RECORD_INPUT_EVENTS, &event)` with
  `sequence_source = INPUT_SEQUENCE_SOURCE_SOFTWARE` (`rpc_gui.c:rpc_system_gui_send_input_event_request_process`).
- RPC is transport-agnostic: `rpc_session_open`/`rpc_session_feed`/`send_bytes_callback` are all
  exported to app code (`api_symbols.csv`).

## Plan B, refined - two firmware variants (both require flashing custom Momentum)

- **B1 (minimal patch):** in `serial_service.c` change `ATTR_PERMISSION_AUTHEN_*` → `ATTR_PERMISSION_NONE`;
  in `serial_profile.c` set pairing to `GapPairingNone`. Connect IQ then reaches the existing RPC directly.
  Smallest change, zero new bridge code. Cost: globally weakens the serial service (any unpaired
  central can reach RPC).
- **B2 (separate service):** add a new unauthenticated GATT service as a `SERVICE`/`STARTUP` app that
  bridges to an internal RPC session, leaving the stock serial service authenticated and intact.
  More C code; better security posture; still a firmware build.

Watch side (Connect IQ / Monkey C) is unchanged by B1 vs B2 - it talks to an unauthenticated GATT
serial endpoint and drives the RPC Gui service.

## Remaining before locking the architecture

1. **Hardware BLE test (§3 task 2/4):** confirm empirically that Connect IQ on Descent Mk2 can connect
   to a "just works" peripheral, subscribe to an INDICATE characteristic, and write RX - and measure MTU.
2. **Latency measurement (§2.5):** press-to-frame on real hardware once B1 patch is flashed.
3. **Framebuffer layout (Phase 2):** confirm bit/page packing of the 1024-byte frame against a known screen.
4. **RPC-status / flow-control semantics** for reconnect (Phase 4).

## Owner decisions pending

- B1 vs B2 (security posture vs. C code volume).
- Custom-firmware distribution is now part of the product. Acceptable, or does flashing kill the
  public-Store premise for the Flipper side?

## Implementation status (2026-08-20)

- **Firmware mod built and verified.** Momentum fork at `../momentum-firmware`, branch
  `feature/open-ble-pairing`, base `dev@d3f89df` (mntm-012). The opt-in toggle compiles and
  links into a full firmware image (`./fbt` → `firmware.elf` + `firmware.bin`, 205 flash pages,
  exit 0). Commit 41a9bb2a3. Five files: settings.h/.c, serial_profile.c, serial_service.c,
  momentum_app_scene_protocols.c. Not yet flashed / not yet tested on hardware.
- **Watch app: Phases 1-4 written.** `watchapp/` - protocol layer (reassembly + PB.Main decode)
  with unit tests, framebuffer render, input mapping, and a connection state machine with reconnect.
  Grounded in the real CIQ BLE API + verified protobuf tags. Cannot be compiled headless (SDK behind
  Garmin login) or validated in the simulator; build + sideload + on-device test + tuning are the
  handoff - see `docs/PROJECT-JOURNAL.md`.
- **Protobuf tags verified** against flipperzero-protobuf @ ea4f185: ping=5/6, gui stream=20/21,
  screen_frame=22, input=23; InputKey UP=0..BACK=5; InputType PRESS=0..REPEAT=4.

## Discovery blocker found on hardware (2026-08-31)

First on-device run: the watch reaches `scanning BLE` and **never sees the Flipper in
`onScanResults`** (diag: "BLE devices seen: 1", and that one device is not the Flipper - it is
present whether the Flipper's BT is on or off). Failure is at discovery, upstream of the
UUID/GATT/CCCD path.

Root cause is two documented Connect IQ platform limitations colliding with how the Flipper
advertises:
- CIQ parses only the **primary ADV_IND** packet, never the **scan response**. The Flipper puts
  its manufacturer data in the scan response (`gap.c:452 hci_le_set_scan_response_data`) - invisible.
- CIQ's advertising parser mis-handles advertisements whose trailing AD structure is a **16-bit
  Service UUID list**. The Flipper advertises name + trailing 16-bit UUID `0x3080`
  (`serial_profile.c:55`, `gap.c:309`), so `getDeviceName()`/`getServiceUuids()` come back
  null/garbage and the name-based match never fires.
  Refs: forums.garmin.com CIQ bug reports "scan response issue" and "advertising layer parsing bug".

Mitigation applied (watch side, `FlipperBleDelegate.onScanResults`): stop trusting the parsed
name/UUIDs; match on the **raw ADV bytes** via `getRawData()` - search for ASCII "Flipper" or the
little-endian `0x80 0x30` UUID pair. Also dumps each seen device's name + first 16 raw bytes to the
diag line so a tester can see exactly what CIQ receives.

If the raw-byte match still does not find the Flipper (i.e. CIQ drops the packet entirely rather
than just mis-parsing it), the fallback is a **firmware-side advertising change**: since we already
ship custom Momentum, reorder/relocate the advertised data so no 16-bit UUID trails the packet
(e.g. drop `adv_svc_uuid` from the serial GapConfig, or move the name last). Confirm first with a
phone BLE scanner (nRF Connect) that the Flipper advertises General-Discoverable + the expected name.

### Actual root cause (2026-08-31): advertising RATE, not flags or parsing

On-device evidence: the watch's CIQ scan surfaces only one device (a fast-advertising phone with
Flags=0x1a incl. General-Discoverable) and never the Flipper - whether the Flipper is on or off.
A phone (iOS/LightBlue) sees the Flipper fine, advertised name `Fa14f31`, connectable, with
inter-packet gaps of **0.85-2.3 s**. That matches the stock low-power advertise interval
(`gap.c`: min `0x0640`=1 s, max `0x0fa0`=2.5 s), which the Flipper drops to after
`INITIAL_ADV_TIMEOUT` (60 s). Connect IQ's scanner is low-duty-cycle: it reliably catches
~100 ms beacons but misses 1-2.5 s ones, so it never sees the Flipper.

Fixes applied:
- **Firmware** (`gap.c gap_advertise_start`): when `open_ble_pairing` is ON, force the fast
  advertising interval (80-100 ms) in the low-power state too, so CIQ catches the beacon. Stock
  timing when OFF. (Also from earlier: the 16-bit `0x3080` adv UUID is dropped when ON.)
- **Watch** (`FlipperBleDelegate`): the Flipper's advertised name need not contain "Flipper"
  (this unit = `Fa14f31`), so matching now also checks a `KNOWN_NAMES` list; the scan view
  accumulates and lists every distinct device seen for diagnosis.

## RPC-silent root cause (2026-08-31): Just Works skips the event that opens RPC

After discovery + connection worked, the watch reached GATT-connected, subscribed to TX, and its
RX writes were ATT-acked (st=0) - but the Flipper sent nothing back (rx=0), and a read of the
RPC-status characteristic (0xfe64) returned **0 = RPC session not active**, even unlocked and
freshly rebooted.

Root cause is in our own mod: `gap.c` emits `GapEventTypeConnected` **only** from the
`ACI_GAP_PAIRING_COMPLETE` handler. `bt.c:bt_open_rpc_connection` (which opens the RPC session and
wires the serial RX callback) is called only on that event. Our Open BLE Pairing mod sets
`GapPairingNone`, and `gap.c` then skips `aci_gap_slave_security_req`, so pairing never happens and
`ACI_GAP_PAIRING_COMPLETE` never fires → `GapEventTypeConnected` never emitted → RPC session never
opens. The central connects at GATT (characteristics are unauthenticated) but the bt service never
learns it is connected.

Fix (`gap.c`, HCI_LE_CONNECTION_COMPLETE): when `pairing_method == GapPairingNone`, emit
`GapEventTypeConnected` directly at connection-complete (gated by the Just Works path, so stock
bonded behaviour is unchanged). Watch-side, `FlipperBleDelegate` now also reads the RPC-status
characteristic and reports it (`rpcCh=`), which is what pinned this down.

##  WORKING CONFIGURATION (2026-09-03) - do not regress these

End-to-end mirror + input verified on Garmin Descent Mk2 ↔ Flipper Zero (Momentum). The exact
parameters that make it work, and WHY - every one of these was a bug that broke the link:

| Parameter | Value | Why it must be this |
|---|---|---|
| `bt->max_packet_size` initial | **20** (not 486) | **THE critical fix.** ATT default MTU is 23 → 20 usable. Connect IQ never negotiates a larger MTU, so the stock 486 default made the Flipper advance its send pointer by 486 while only 20 bytes reached the client - 466 of every 486 bytes lost, client reassembled garbage (diagonal shear). `GapEventTypeUpdateMTU` still raises it if a central does negotiate. |
| TX characteristic | **INDICATE** (CCCD `0x0002`) | Confirmed per packet ⇒ cannot drop. NOTIFY (unconfirmed) loses occasional packets in the ~52-packet burst, which shifts the rest of the frame. NOTIFY *appeared* necessary only because the MTU bug made INDICATE look unusably slow. |
| `GapEventTypeConnected` | emitted on `HCI_LE_CONNECTION_COMPLETE` when `pairing_method == GapPairingNone` | Stock emits it only from `ACI_GAP_PAIRING_COMPLETE`, which never fires without pairing ⇒ `bt_open_rpc_connection` never ran ⇒ GATT connected but RPC silent. |
| Serial service UUIDs | byte-**reversed** from `serial_service_uuid.inc` | The `.inc` lists bytes little-endian (STM32WB ACI). Over the air: service `8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000`, RX `...62fe0000`, TX `...61fe0000`. |
| Advertising | keep 16-bit UUID `0x3080`, force fast interval while toggle ON | CIQ's scanner only surfaces 16-bit-UUID advertisers and misses slow (1-2.5 s) beacons. |
| Frame size | **exactly 1024 bytes**, else reject | `tile_width 16 × tile_height 8 × 8`. Any other size = mis-parsed/desynced stream. |
| Framebuffer layout | `byte = x + (y>>3)*128`, bit 0 = top | Verified against `u8g2_ll_hvline_vertical_top_lsb`: `offset = (y & ~7) * tile_width + x`. |
| Render | two half-height passes, `MAX_RECTS` cap, throttled ~1/s | Connect IQ trips a "Code Executed Too Long" watchdog otherwise (confirmed in `CIQ_LOG.YML` stack traces pointing at `Framebuffer.draw`). |

### Debugging infrastructure that made this tractable
- **Flipper logs over USB CLI** (`/dev/ttyACM0`, `log info`) - `TXMSG <len> mps=<n>` revealed `mps=486`.
- **Watch crash log over MTP**: `mtp://.../Primary/GARMIN/Apps/LOGS/CIQ_LOG.YML` - exact watchdog stack traces.
- **Sideload over MTP**: copy `.prg` to `.../Primary/GARMIN/Apps/`.
- **Flash firmware over USB**: `./fbt flash_usb_full`.
- **Decoder unit-testable off-device**: the reassembly/parse is pure byte logic; a Python port with a
  synthetic 1024-byte frame chunked to 20 bytes verifies it without hardware.

## The one remaining gate (needs the user's hardware)
Whether Connect IQ on the Descent Mk2 actually connects to the Just-Works Flipper, subscribes to
the INDICATE TX characteristic, writes RX, and what MTU/latency result. Source analysis is
unambiguous that the mod removes the auth block; only on-device BLE behaviour can confirm the
transport end-to-end.
