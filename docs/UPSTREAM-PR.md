# Draft: upstream PR to Next-Flip/Momentum-Firmware

**Status:** draft, not opened. Open only after the approval prompt has been exercised on hardware -
submitting a security-relevant change that has never run would waste the maintainers' time and
our credibility.

Source branch: `rz-x/momentum-firmware-for-garmin:feature/open-ble-pairing`
Commits: `44b4a61`, `69817d5`, `a7d7cfb`, `968af52`

---

## Title

Open BLE Pairing: make RPC usable by non-bonding centrals, with an on-device approval prompt

## Summary

`open_ble_pairing` exists so that a BLE central without SMP support can reach the serial/RPC
profile. As shipped it did not actually work end to end, and where it did work it exposed RPC to
any device in range. This PR fixes the former and closes the latter.

Motivating client: a Garmin Connect IQ watch app that mirrors the Flipper's screen and relays
buttons. Connect IQ's BLE stack cannot bond, cannot negotiate MTU and cannot set connection
parameters, so every one of these had to be handled on the Flipper side.

## What was broken with `open_ble_pairing` on

1. **RPC session never opened.** `GapEventTypeConnected` was only emitted from
   `ACI_GAP_PAIRING_COMPLETE`, which never fires without pairing. Now emitted on
   `HCI_LE_CONNECTION_COMPLETE` when `pairing_method == GapPairingNone`.
2. **Frames were silently truncated.** `bt->max_packet_size` started at 486 regardless of the
   negotiated MTU. At the default 23-byte MTU only 20 bytes of each 486-byte chunk went out and
   the send pointer still advanced by 486. Now starts at 20 under open pairing and is raised by
   `GapEventTypeUpdateMTU`.
3. **Connection interval never renegotiated.** The check was gated on `gap->is_secure`, which is
   only set through pairing. A central proposing 997 ms was accepted as-is. The gate now also
   admits `GapPairingNone`; measured 997 ms → 7 ms in one round.
4. **Slow advertising.** Fast interval is forced while the setting is on.
5. **MTU exchange.** `aci_gatt_exchange_config()` is requested at connection and retried once at
   `HCI_LE_CONNECTION_UPDATE_COMPLETE`, where the first attempt has been observed to return
   `BLE_STATUS_FAILED`. (Retry effect not yet measured.)

## Security change

With no pairing there is no authentication of any kind, so before this PR enabling the setting
meant any BLE central in range could open an RPC session. New `GapEventTypeConnectionRequest`
is emitted before `Connected` on a Just Works link; the bt service answers from an allowlist in
`/int/.bt_open_allow` or asks the user (Deny/Allow with the peer address). Deny terminates the
link before any service is reachable. "Forget BLE Remotes" in Momentum settings clears the list.

Address-based matching is a known limitation for centrals using resolvable private addresses.

## Files

- `targets/f7/ble_glue/gap.c`, `gap.h` - Connected on Just Works, interval gate, MTU exchange +
  retry, ConnectionRequest event
- `applications/services/bt/bt_service/bt.c` - max_packet_size, INDICATE confirmation wait,
  connection-request handler
- `applications/services/bt/bt_service/bt_open_pairing_allowlist.{c,h}` - new
- `applications/main/momentum_app/scenes/momentum_app_scene_protocols.c` - Forget BLE Remotes
- `targets/f7/ble_glue/services/serial_service.c`, `profiles/serial_profile.c` - permission /
  pairing relaxation (pre-existing in the branch)

## Testing

- Descent Mk2 + Flipper Zero: connection, correct 1024-byte screen frames, input, interval
  renegotiation verified with logs (2026-09-03).
- Approval prompt, allowlist, Forget: **build-verified only** as of this draft.

## Out of scope

Switching the serial characteristic from INDICATE to NOTIFY (throughput) - deliberately not
proposed; a lost packet would desynchronise RPC's varint framing.

