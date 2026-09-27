# Flipper Watch Remote

## What This Is

A Garmin Connect IQ watch app that acts as a remote monitor and control head for a Flipper Zero over Bluetooth Low Energy. The watch mirrors the Flipper's screen and relays button presses back to it, so the whole device can be driven as-is - whatever app is running on the Flipper - while the Flipper itself stays stowed in a pocket or bag. Targets the fēnix / epix / tactix families and is intended for public release on the Connect IQ Store.

## Core Value

From the wrist, the user can see the Flipper's current screen and navigate it - menu to menu, action to action - without taking the Flipper out.

## Business Context

- **Customer**: Flipper Zero owners who also wear a fēnix / epix / tactix watch
- **Revenue model**: Not decided - Connect IQ Store distribution, free vs. paid unresolved
- **Success metric**: Not decided - candidate is Store installs retained past first week
- **Strategy notes**: None

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet - ship to validate)

### Active

<!-- Current scope. Building toward these. All are hypotheses until shipped. -->

- [ ] Watch discovers a Flipper Zero over BLE and establishes a working link
- [ ] Watch renders the Flipper's 128×64 screen, refreshed on change at a best-effort rate
- [ ] Watch sends directional, OK, and Back input to the Flipper, including long-press
- [ ] Input round-trip feels responsive enough to navigate menus without overshooting
- [ ] Connection state is always legible on the watch (connected / reconnecting / lost)
- [ ] Link recovers on its own after the Flipper goes out of range or sleeps
- [ ] App runs across fēnix / epix / tactix resolutions and both MIP and AMOLED displays
- [ ] App passes Garmin Connect IQ Store review, including BLE permission justification

### Out of Scope

<!-- Explicit boundaries. Reasoning included to prevent re-adding. -->

- Per-feature Flipper integrations - dedicated Sub-GHz, IR, NFC, or RFID screens on the watch - the generic screen mirror already reaches every one of those, and feature-specific UIs would duplicate the Flipper's own menus and need maintenance per firmware change
- Non-fēnix watch families (Venu, vívoactive, Instinct, Forerunner) in v1 - different button counts, screen budgets, and memory ceilings; the 5-button fēnix layout is the design anchor and other families come later if at all
- File transfer, capture offload, and log sync - monitoring and control is the product; moving files is qFlipper's job over USB
- Flipper firmware flashing or updates from the watch - unacceptable risk over a best-effort wireless link
- Pixel-accurate full-motion mirroring - deliberately traded away; see Key Decisions
- Standalone operation without a Flipper present - the app is a remote head, not a simulator

## Context

**What the Flipper already exposes.** Stock Flipper Zero firmware carries a BLE serial service and a protobuf-based RPC protocol, the same one qFlipper and the official mobile apps use. Its `Gui` service is the relevant surface: a screen-frame stream out of the device and input-event injection into it - exactly the two directions this project needs. This is why the Flipper-side question was left to research rather than answered up front: if the shipped RPC covers it, the project has one deliverable instead of two.

**The load-bearing unknown.** Whether Connect IQ's `Toybox.BluetoothLowEnergy` can hold the Flipper's BLE serial link at all. Connect IQ puts the watch in the GATT central role with a restrictive stack, and the Flipper's serial service expects a bonded, encrypted connection. If Connect IQ cannot establish or maintain that, the project's shape changes. Known fallback directions, in rough order of preference: a custom Flipper-side GATT service with characteristics Connect IQ can talk to unencrypted; or a phone relay between watch and Flipper. This must be settled before any roadmap commitment - it decides whether one deliverable or two, and whether the watch talks to the Flipper directly at all. **Resolved 2026-08-20 (Outcome B):** Momentum's serial characteristics require an authenticated (bonded) link, which Connect IQ cannot do. The chosen path is an opt-in Momentum firmware toggle ("Open BLE Pairing") that exposes the existing RPC unauthenticated - **two deliverables** (watch app + firmware mod), watch talks directly to the Flipper once the toggle is on. See `docs/spike-0-findings.md`.

**Throughput is the design budget.** A raw 128×64 monochrome frame is roughly 1 KB. Connect IQ BLE throughput and MTU limits are modest, so full-rate mirroring is not on the table and was explicitly traded away. The working assumption is update-on-change plus a low ceiling, with input latency prioritized over refresh smoothness.

**No protobuf library exists for Monkey C.** If the stock RPC path is taken, encoding and decoding the needed subset of Flipper protobuf messages has to be hand-written in Monkey C. That is tractable for a small message set but is real work and a source of subtle bugs; it argues for keeping the message subset as small as possible.

**Input mapping is a genuine design problem.** The Flipper has a 5-way pad plus Back. The fēnix family has five physical buttons whose default semantics (start/stop, back/lap, light, up, down) do not map one-to-one, and Connect IQ intercepts some of them. Resolving this into something usable without a manual is a design task, not an implementation detail.

**Store release raises the floor.** Publishing to the Connect IQ Store adds multi-device layout work across several resolutions and two display technologies, store assets, and a review pass that will scrutinize the BLE permission request. It also implies a support burden after launch.

## Constraints

- **Tech stack**: Monkey C on the Connect IQ SDK, using `Toybox.BluetoothLowEnergy` in the central role - the only way a Garmin watch app can speak BLE to a third-party device
- **Compatibility**: fēnix / epix / tactix families across multiple resolutions and both MIP and AMOLED - required for a credible Store listing
- **Dependencies**: Flipper Zero BLE serial + protobuf RPC - reachable via the opt-in Momentum "Open BLE Pairing" mod (stock characteristics are authenticated and unreachable by Connect IQ). Firmware: Momentum. Dev watch: Descent Mk2.
- **Performance**: best-effort screen refresh (update-on-change, low frame ceiling); input responsiveness takes priority over refresh rate - Connect IQ BLE throughput will not support full-motion mirroring
- **Platform**: Garmin Connect IQ Store review, including justification for the BLE permission - gates release
- **Protocol**: no protobuf library for Monkey C; any RPC message handling is hand-rolled - keeps pressure on minimizing the message subset
- **Memory**: Connect IQ app memory ceilings are tight relative to holding frame buffers plus protocol state - constrains buffering strategy

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Generic screen mirror + input relay, not per-feature integrations | One protocol reaches every Flipper app at once; zero work per Flipper feature; matches the intent of controlling the device "as is" | - Pending |
| Target fēnix / epix / tactix first | Five physical buttons give the best shot at a usable D-pad mapping, and the family sits at the widest Connect IQ API tier | - Pending |
| Best-effort refresh over live mirroring | Connect IQ BLE throughput is the binding constraint; being able to navigate reliably matters more than a smooth image | - Pending |
| Flipper-side software deferred to research | Stock firmware RPC may already cover both directions; avoid committing to a second deliverable before knowing | Resolved 2026-08-20: **two deliverables**. Stock serial is authenticated (Connect IQ can't bond); ship an opt-in Momentum mod "Open BLE Pairing" exposing RPC unauthenticated. |
| Publish to the Connect IQ Store | Public distribution is the stated goal, accepted along with review, multi-device, and support cost | - Pending |
| Screen mirroring kept in scope despite bandwidth risk | Without a mirror the user navigates blind, which defeats the core value; the fallback is lower frame rate, not dropping the mirror | - Pending |

## Maintenance

This document is the source of truth for what is being built and why. Keep it current - a stale PROJECT.md silently misleads every later decision.

**Update it when a phase completes:**
1. Requirement shipped and confirmed? → move to Validated, noting the phase
2. Requirement invalidated? → move to Out of Scope with the reason
3. New requirement emerged? → add to Active
4. Decision made that constrains future work? → add to Key Decisions and set the Outcome of any it supersedes
5. "What This Is" drifted from reality? → rewrite it

**Settled on hardware:** press-to-frame latency, not frame rate, is the metric. Measured at roughly two seconds per frame on a Descent Mk2, bounded by the 23-byte ATT MTU.

The build history, including the feasibility gate that preceded everything, is in `docs/PROJECT-JOURNAL.md`; open problems are in `docs/KNOWN-ISSUES.md`.

---
*Last updated: 2026-08-20 after Phase 0 gate resolved (Outcome B) and dev of the watch app + firmware mod.*
