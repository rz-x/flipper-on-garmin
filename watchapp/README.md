# Flipper Remote - Connect IQ watch app (Phase 0 spike)

Watch side of the two-part project. Talks to a Flipper Zero running **Momentum with
"Open BLE Pairing" enabled** (see `../../momentum-firmware`, branch
`feature/open-ble-pairing`). Target dev device: **Garmin Descent Mk2**.

## Status
Phase-0 spike scaffold. Proves transport: register profile → scan → connect →
subscribe to the TX indication → write a `System.PingRequest` → log the reply and
its round-trip latency. Not the product UI yet.

## What is grounded vs. what needs hardware
- **Grounded in source:** service/characteristic UUIDs (Momentum `serial_service_uuid.inc`),
  TX is INDICATE (CCCD `0x0002`), protobuf field numbers (`flipperzero-protobuf` @ ea4f185).
- **Needs the SDK + watch (not installable headless):** the Connect IQ SDK is behind a
  Garmin login, and BLE cannot be validated in the simulator. The steps below are the handoff.

## Build & sideload (requires Connect IQ SDK)
1. Install the Connect IQ SDK via Garmin's SDK Manager; add a device build for Descent Mk2.
2. Generate a developer key:
   `openssl genrsa -out developer_key.pem 4096 && openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key -nocrypt`
3. Set a real `id` in `manifest.xml` (SDK: `monkeyc` warns if the placeholder is used) and
   confirm the Descent Mk2 product id + BLE-capable `minSdkVersion` against `$SDK/bin/devices`.
4. Build: `monkeyc -f monkey.jungle -o bin/FlipperRemote.prg -y developer_key -d descentmk2`
5. Sideload the `.prg` to the watch (Garmin Express / Connect IQ device connection).

## On-device test (the real Phase-0 gate)
1. On the Flipper (Momentum): **Momentum > Protocols > Open BLE Pairing = ON**, then reboot BT.
2. Launch Flipper Remote on the watch. Expected status line progression:
   `registering profile → scanning → found Flipper → connected → CCCD write: 0 → ping sent → RX <N>B (+<ms>)`.
3. Record: does RX return bytes? the +ms latency. the negotiated MTU (log via SDK).
4. If ping works, extend to `StartScreenStreamRequest` (Protocol.buildEmptyContent(20)) and
   measure press-to-frame latency.

## Files
- `source/Protocol.mc` - varint + PB.Main framing + Ping/Input/Stream encoders (verified tags).
- `source/FlipperBleDelegate.mc` - BLE central: profile, scan, connect, subscribe, ping.
- `source/FlipperRemoteView.mc` - status line (Phase 2 replaces with framebuffer render).
- `source/FlipperRemoteApp.mc` - app entry.
