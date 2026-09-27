using Toybox.BluetoothLowEnergy as Ble;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.Application;

// The single Ble.BleDelegate for the app. Owns the connection state machine, the screen-stream
// lifecycle, fragment reassembly, and reconnect. Talks to a Flipper running Momentum with
// "Open BLE Pairing" enabled (unauthenticated serial service, Just Works pairing).
//
// UUIDs: serial_service_uuid.inc lists bytes LITTLE-ENDIAN (STM32WB ACI convention), so the
// over-the-air UUIDs are the byte-reversed form. Confirmed against central-side clients
// (e.g. flipper-zero-bluetooth-serial-poc): service 8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000.
//   RX ...62fe0000 (write, host->Flipper)   TX ...61fe0000 (INDICATE, Flipper->host)
//   RpcStatus ...64fe0000
// Under Open BLE Pairing the firmware exposes TX as NOTIFY (not INDICATE) so it can stream
// packets without a per-packet client confirmation → CCCD is written 0x0001 (notify).
class FlipperBleDelegate extends Ble.BleDelegate {

    // Flipper advertises 0x3080 OR'ed with the hardware-color byte.
    // Therefore the wire value is normally 0x3081 (black), 0x3082
    // (white), or 0x3083 (transparent), not exactly 0x3080.
    // The GATT service itself is the separate 128-bit UUID below.
    const ADV_SERVICE_UUID_BASE  = "00003080-0000-1000-8000-00805f9b34fb"; // the actual advertised 16-bit UUID
    const ADV_SERVICE_UUID_BLACK = "00003081-0000-1000-8000-00805f9b34fb";
    const ADV_SERVICE_UUID_WHITE = "00003082-0000-1000-8000-00805f9b34fb";
    const ADV_SERVICE_UUID_TRANSPARENT = "00003083-0000-1000-8000-00805f9b34fb";
    const SERVICE_UUID  = "8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000";
    const CHAR_RX_UUID  = "19ed82ae-ed21-4c9d-4145-228e62fe0000";
    const CHAR_TX_UUID  = "19ed82ae-ed21-4c9d-4145-228e61fe0000";
    const CHAR_RPC_UUID = "19ed82ae-ed21-4c9d-4145-228e64fe0000";
    const CCCD_NOTIFY = [0x02, 0x00]b;   // TX is INDICATE (confirmed per packet) → CCCD 0x0002

    // Flipper detection is heuristic (advertised 16-bit UUID 0x3080-0x3083, GAP appearance
    // 0x8600, "Flipper" in the name or raw payload). The BLE name is user-settable and need not
    // contain "Flipper", so a device can slip through; the picker's "all devices" list is the
    // fallback for that - not a hardcoded name list, which only ever fit one developer's unit.
    const STORAGE_LAST_FLIPPER = "lastFlipper";   // Application.Storage key: remembered device name
    const REMEMBER_WAIT_MS = 6000;   // remembered device not seen for this long → show the picker
    const APPROVAL_POLL_MS = 2000;   // re-read the RPC-status char while the Flipper asks its user
    const APPROVAL_POLL_MAX = 45;    // ~90 s for the user to reach the Flipper and press Allow

    const PING_TIMEOUT_MS = 4000;   // no pong within this → retry, then try the stream directly
    const MAX_PING_ATTEMPTS = 3;    // ping retries before falling back to starting the stream
    const RECONNECT_MS = 1500;      // delay before re-scanning after a drop

    var _device = null;
    var _service = null;
    var _rx = null;
    var _tx = null;
    var _reader = null;
    var _state = ConnState.IDLE;

    var _onState = null;            // Method(Number)
    var _onFrame = null;            // Method(ByteArray)
    var _onDiag = null;             // Method(String)
    var _onStats = null;            // Method(rssi, txCount, rxBytes, fps10)
    var _onInputSent = null;        // Method() -> view pops one queued keypress glyph
    var _rssi = 0;                  // signal strength captured when we picked the device
    var _inputSent = 0;             // input frames actually written to the Flipper
    var _fps10 = 0;                 // screen frames/sec x10
    var _fpsWindowTick = 0;
    var _fpsWindowFrames = 0;
    var _lastInputTick = 0;
    var _txQueue = null;            // Array of pending ByteArray frames (CIQ: 1 op in flight max)
    var _writePending = false;
    const TX_QUEUE_MAX = 12;
    var _pingTimer = null;
    var _reconnectTimer = null;
    var _stopped = false;           // user left the app → do not auto-reconnect
    var _seenLabels = null;         // Array<String> of distinct devices seen while scanning
    var _scanCallbacks = 0;         // # times onScanResults fired this scan
    var _scanResultsTotal = 0;      // # ScanResults delivered this scan
    var _scanWatchdog = null;       // periodic timer: reports scan health + restarts a stalled scan
    var _rxBytes = 0;               // total bytes received on TX (indications) this connection
    var _rxFrames = 0;              // total complete PB.Main frames reassembled this connection
    var _pingAttempts = 0;          // ping tries since subscribe (drives retry → stream fallback)
    var _txAcks = 0;                // # RX writes ATT-acked by the Flipper (proves writes land)
    var _lastWriteStatus = -1;      // status of the last characteristic write
    var _rpcChar = null;            // RPC-status characteristic (0xfe64): 1 = RPC session active
    var _rpcVal = -2;               // last read value of the RPC-status char (-2 = not read)
    var _rpcReadStatus = -2;        // status of that read
    var _rxDump = null;             // first bytes received on TX, kept as hex for on-screen debug
    var _indSizes = null;           // sizes of the first inbound notifications/indications
    var _nonTxNotifs = 0;           // notifications received from a NON-TX characteristic (should be 0)
    var _badFrames = 0;             // frames rejected because their size wasn't exactly 1024
    var _inputQueued = 0;           // input frames sitting at the FRONT of the tx queue (priority)
    var _frameInfo = "";            // decode result of the first assembled frame (self-diagnosis)
    var _pongCount = 0;             // frames decoded as ping-response
    var _scrCount = 0;              // frames decoded as screen frames
    var _otherCount = 0;            // frames decoded as neither (unexpected - shows their field)
    var _streamRequested = false;   // StartScreenStream sent → show live RX byte flow while waiting
    var _streamWatchdog = null;     // interval timer that samples RX flow while awaiting frames
    var _disconnects = 0;           // count of link drops (distinguishes disconnect from stale frame)
    var _candidates = [] as Lang.Array;  // devices seen this scan: {:key,:name,:rssi,:flipper,:result}
    var _onCandidates = null;       // Method(Array candidates, Boolean forcePicker)
    var _remembered = null;         // BLE name of the Flipper chosen last time, or null
    var _scanStartTick = 0;
    var _forcedPick = false;        // picker already forced once this scan
    var _approvalTimer = null;      // polls RPC status while the Flipper's user decides
    var _approvalPolls = 0;
    var _refused = false;           // link closed before anything arrived → likely denied on Flipper
    var _lastRenderTick = 0;        // throttle rendering: streaming frames faster than the watch
                                    // can draw them piles up and crashes the app (OOM/watchdog)

    function initialize(onState as Lang.Method, onFrame as Lang.Method, onDiag as Lang.Method,
                        onStats as Lang.Method, onInputSent as Lang.Method) {
        BleDelegate.initialize();
        _onState = onState;
        _onFrame = onFrame;
        _onDiag = onDiag;
        _onStats = onStats;
        _onInputSent = onInputSent;
        _reader = new FrameReader(method(:onFrameBody));
    }

    function setCandidatesCallback(cb as Lang.Method) as Void { _onCandidates = cb; }

    function hasRemembered() as Lang.Boolean { return _remembered != null; }
    function remembered() as Lang.String or Null { return _remembered; }

    function forgetRemembered() as Void {
        _remembered = null;
        try { Application.Storage.deleteValue(STORAGE_LAST_FLIPPER); } catch (ex) { }
    }

    function candidates() as Lang.Array { return _candidates; }

    // The user asked to choose a device (ENTER while not streaming). Make sure a scan is running
    // so the list is live, then have the app open the picker.
    function requestPicker() as Void {
        _refused = false;
        if (_state != ConnState.SCANNING) {
            if (_device != null) {
                try { Ble.unpairDevice(_device); } catch (ex) { }
                _device = null;
            }
            beginScan();
        }
        if (_onCandidates != null) { _onCandidates.invoke(_candidates, true); }
    }

    // Connect to a device the user (or the remembered-name rule) picked.
    function connectTo(item as Lang.Dictionary) as Void {
        var r = item[:result];
        if (r == null) { return; }
        _rssi = item[:rssi];
        diag("connecting: " + item[:name]);
        if (_scanWatchdog != null) { _scanWatchdog.stop(); _scanWatchdog = null; }
        Ble.setScanState(Ble.SCAN_STATE_OFF);
        setState(ConnState.FOUND);
        setState(ConnState.CONNECTING);
        _remembered = item[:name];
        try { Application.Storage.setValue(STORAGE_LAST_FLIPPER, _remembered); } catch (ex) { }
        _device = Ble.pairDevice(r);
    }

    function diag(message as Lang.String) as Void {
        System.println("diag: " + message);
        if (_onDiag != null) { _onDiag.invoke(message); }
    }

    // ---- lifecycle ----
    function start() as Void {
        _stopped = false;
        setState(ConnState.STARTING);
        try {
            diag("setting delegate");
            Ble.setDelegate(self);
            diag("registering profile");
            Ble.registerProfile(makeProfile());
            beginScan();
        } catch (ex) {
            diag("init err: " + ex.getErrorMessage());
        }
    }

    function stop() as Void {
        _stopped = true;
        stopStream();
        if (_scanWatchdog != null) { _scanWatchdog.stop(); _scanWatchdog = null; }
        if (_streamWatchdog != null) { _streamWatchdog.stop(); _streamWatchdog = null; }
        if (_approvalTimer != null) { _approvalTimer.stop(); _approvalTimer = null; }
        Ble.setScanState(Ble.SCAN_STATE_OFF);
        setState(ConnState.IDLE);
    }

    function makeProfile() as Lang.Dictionary {
        return {
            :uuid => Ble.stringToUuid(SERVICE_UUID),
            :characteristics => [
                { :uuid => Ble.stringToUuid(CHAR_RX_UUID) },
                { :uuid => Ble.stringToUuid(CHAR_TX_UUID), :descriptors => [ Ble.cccdUuid() ] },
                { :uuid => Ble.stringToUuid(CHAR_RPC_UUID) }
            ]
        };
    }

    function setState(s as Lang.Number) as Void {
        _state = s;
        System.println("state: " + ConnState.label(s));
        if (_onState != null) { _onState.invoke(s); }
    }

    function getState() as Lang.Number { return _state; }

    // ---- BleDelegate callbacks ----
    // status 0 == STATUS_SUCCESS. On success stay quiet so the live scan-result list remains
    // on screen (this fires late and would otherwise overwrite it); only surface a failure.
    function onProfileRegister(uuid, status) as Void {
        System.println("profile reg status " + status);
        if (status != Ble.STATUS_SUCCESS) {
            diag("profile reg FAILED " + status);
        }
    }

    function beginScan() as Void {
        _seenLabels = [] as Lang.Array;
        _scanCallbacks = 0;
        _scanResultsTotal = 0;
        _candidates = [] as Lang.Array;
        _forcedPick = false;
        _scanStartTick = System.getTimer();
        try { _remembered = Application.Storage.getValue(STORAGE_LAST_FLIPPER); } catch (ex) { _remembered = null; }
        setState(ConnState.SCANNING);
        try {
            Ble.setScanState(Ble.SCAN_STATE_SCANNING);
            diag("scan active");
        } catch (ex) {
            diag("scan err: " + ex.getErrorMessage());
        }
        startScanWatchdog();
    }

    // Periodically reports whether CIQ's scanner is firing at all (cb = callbacks, res = results),
    // and re-asserts SCAN_STATE_SCANNING in case the stack silently stalled. This is how we tell
    // "CIQ scan is dead" (cb stays 0) apart from "scan works but the Flipper isn't in range".
    function startScanWatchdog() as Void {
        if (_scanWatchdog != null) { _scanWatchdog.stop(); }
        _scanWatchdog = new Timer.Timer();
        _scanWatchdog.start(method(:onScanWatchdog), 3000, true); // repeating
    }
    function onScanWatchdog() as Void {
        if (_state != ConnState.SCANNING) {
            if (_scanWatchdog != null) { _scanWatchdog.stop(); _scanWatchdog = null; }
            return;
        }
        // Remembered Flipper not showing up: stop waiting for it and let the user pick.
        if (!_forcedPick && _remembered != null && _candidates.size() > 0 &&
            System.getTimer() - _scanStartTick > REMEMBER_WAIT_MS) {
            _forcedPick = true;
            diag("'" + _remembered + "' not seen - choose a device");
            if (_onCandidates != null) { _onCandidates.invoke(_candidates, true); }
        }
        if (_seenLabels != null && _seenLabels.size() > 0) { return; } // list is showing devices
        // Nothing seen yet - report scanner health and kick the scan again.
        diag("scanning... cb=" + _scanCallbacks + " res=" + _scanResultsTotal);
        try {
            Ble.setScanState(Ble.SCAN_STATE_OFF);
            Ble.setScanState(Ble.SCAN_STATE_SCANNING);
        } catch (ex) {
            diag("rescan err: " + ex.getErrorMessage());
        }
    }

    // onScanResults is called repeatedly, each time with a fresh batch - and the on-screen diag
    // only shows the latest line, so a device seen in an earlier batch scrolls away. We therefore
    // ACCUMULATE every distinct device seen this scan and show the whole list, so a hardware
    // tester can spot a Flipper advertising under a *custom* name (the watch can't assume the
    // name contains "Flipper"). CIQ can only parse the primary ADV_IND packet (never the scan
    // response) and mis-parses some advertisements, so we also raw-match and log raw bytes.
    function onScanResults(scanResults as Ble.Iterator) as Void {
        if (_seenLabels == null) { _seenLabels = [] as Lang.Array; }
        _scanCallbacks += 1;
        for (var r = scanResults.next() as Ble.ScanResult; r != null; r = scanResults.next() as Ble.ScanResult) {
            _scanResultsTotal += 1;
            var devName = r.getDeviceName();
            var raw = null;
            try { raw = r.getRawData(); } catch (ex) { raw = null; }
            var appearance = 0;
            try { appearance = r.getAppearance(); } catch (ex) { appearance = 0; }

            var label = (devName != null) ? devName : ("?" + (raw != null ? hexPreview(raw, 6) : ""));
            noteSeen(label);

            var isFlipper = false;
            if (devName != null && devName.find("Flipper") != null) { isFlipper = true; }
            if (!isFlipper && raw != null &&
                (bytesContainAscii(raw, "Flipper") || bytesContainPair(raw, 0x80, 0x30))) {
                isFlipper = true;
            }
            if (!isFlipper && appearance == 0x8600) { isFlipper = true; } // Flipper GAP appearance
            if (!isFlipper) {
                var uuids = r.getServiceUuids();
                var t128 = Ble.stringToUuid(SERVICE_UUID);
                var tAdv = Ble.stringToUuid(ADV_SERVICE_UUID_BASE);  // 0x3080, what CIQ keys on
                var tB = Ble.stringToUuid(ADV_SERVICE_UUID_BLACK);
                var tW = Ble.stringToUuid(ADV_SERVICE_UUID_WHITE);
                var tT = Ble.stringToUuid(ADV_SERVICE_UUID_TRANSPARENT);
                for (var u = uuids.next(); u != null; u = uuids.next()) {
                    if (u.equals(t128) || u.equals(tAdv) || u.equals(tB) || u.equals(tW) || u.equals(tT)) {
                        isFlipper = true; break;
                    }
                }
            }

            var rssi = 0;
            try { rssi = r.getRssi(); } catch (ex) { rssi = 0; }
            var item = upsertCandidate(label, rssi, isFlipper, r);

            // No device connects on its own - not even the one chosen last time. The list always
            // appears, with the remembered device preselected so one press connects; the user
            // always sees which Flipper they are about to take control of.
        }
        if (_onCandidates != null) { _onCandidates.invoke(_candidates, false); }
    }

    // Keep one entry per device, refreshed with the latest RSSI and ScanResult.
    function upsertCandidate(label as Lang.String, rssi as Lang.Number, isFlipper as Lang.Boolean,
                             r as Ble.ScanResult) as Lang.Dictionary {
        for (var i = 0; i < _candidates.size(); i++) {
            var c = _candidates[i];
            if (c[:key].equals(label)) {
                c[:rssi] = rssi;
                c[:result] = r;
                if (isFlipper) { c[:flipper] = true; }
                return c;
            }
        }
        var item = { :key => label, :name => label, :rssi => rssi, :flipper => isFlipper, :result => r };
        _candidates.add(item);
        return item;
    }

    // Record a distinct device label and push the accumulated list to the screen.
    function noteSeen(label as Lang.String) as Void {
        if (_seenLabels == null) { _seenLabels = [] as Lang.Array; }
        for (var i = 0; i < _seenLabels.size(); i++) {
            if (_seenLabels[i].equals(label)) { return; }   // already listed
        }
        _seenLabels.add(label);
        var joined = "";
        for (var i = 0; i < _seenLabels.size(); i++) {
            joined += (i == 0 ? "" : " | ") + _seenLabels[i];
        }
        diag(_seenLabels.size() + ": " + joined);
    }

    // Hex of `count` bytes starting at `off` (bounded), for the frame-content diagnostic.
    function hexAtDel(b as Lang.ByteArray, off as Lang.Number, count as Lang.Number) as Lang.String {
        var digits = "0123456789abcdef";
        var s = "";
        for (var i = 0; i < count && (off + i) < b.size(); i++) {
            var v = b[off + i] & 0xff;
            s += digits.substring(v >> 4, (v >> 4) + 1) + digits.substring(v & 0xf, (v & 0xf) + 1);
        }
        return s;
    }

    // Per-page non-zero byte counts of a 1024-byte framebuffer (8 pages × 128 bytes).
    function pageCounts(frame as Lang.ByteArray) as Lang.String {
        var s = "";
        var n = frame.size();
        for (var p = 0; p < 8; p++) {
            var c = 0;
            var base = p * 128;
            for (var i = 0; i < 128; i++) {
                if (base + i < n && frame[base + i] != 0) { c++; }
            }
            s += (p == 0 ? "" : ",") + c;
        }
        return s;
    }

    // Join an array of numbers with commas (notification sizes for diagnostics).
    function joinNums(a as Lang.Array or Null) as Lang.String {
        if (a == null) { return ""; }
        var s = "";
        for (var i = 0; i < a.size(); i++) { s += (i == 0 ? "" : ",") + a[i]; }
        return s;
    }

    // First `max` bytes of a ByteArray as hex, for the on-screen diagnostic line.
    function hexPreview(b as Lang.ByteArray, max as Lang.Number) as Lang.String {
        var digits = "0123456789abcdef";
        var s = "";
        var n = (b.size() < max) ? b.size() : max;
        for (var i = 0; i < n; i++) {
            var v = b[i] & 0xff;
            s += digits.substring(v >> 4, (v >> 4) + 1) + digits.substring(v & 0xf, (v & 0xf) + 1);
        }
        return s;
    }

    // True if the ByteArray contains the ASCII bytes of `needle` (used to find "Flipper" in raw adv).
    function bytesContainAscii(hay as Lang.ByteArray, needle as Lang.String) as Lang.Boolean {
        var nb = needle.toUtf8Array();
        var hn = hay.size();
        var nn = nb.size();
        if (nn == 0 || hn < nn) { return false; }
        for (var i = 0; i <= hn - nn; i++) {
            var ok = true;
            for (var j = 0; j < nn; j++) {
                if ((hay[i + j] & 0xff) != (nb[j] & 0xff)) { ok = false; break; }
            }
            if (ok) { return true; }
        }
        return false;
    }

    // True if two consecutive bytes a,b appear anywhere (used to find the 16-bit UUID 0x3080,
    // which is little-endian on the wire → 0x80 0x30).
    function bytesContainPair(hay as Lang.ByteArray, a as Lang.Number, b as Lang.Number) as Lang.Boolean {
        for (var i = 0; i + 1 < hay.size(); i++) {
            if ((hay[i] & 0xff) == a && (hay[i + 1] & 0xff) == b) { return true; }
        }
        return false;
    }

    function onConnectedStateChanged(device, state) as Void {
        diag("connection state " + state);
        if (state == Ble.CONNECTION_STATE_CONNECTED) {
            _device = device;
            _service = device.getService(Ble.stringToUuid(SERVICE_UUID));
            if (_service == null) { diag("service missing"); setState(ConnState.DEGRADED); return; }
            _rx = _service.getCharacteristic(Ble.stringToUuid(CHAR_RX_UUID));
            _tx = _service.getCharacteristic(Ble.stringToUuid(CHAR_TX_UUID));
            _rpcChar = _service.getCharacteristic(Ble.stringToUuid(CHAR_RPC_UUID));
            _reader.reset();
            _txQueue = [] as Lang.Array;
            _inputQueued = 0;
            _writePending = false;
            _rxBytes = 0;
            _rxFrames = 0;
            _pingAttempts = 0;
            _txAcks = 0;
            _rpcVal = -2;
            _rpcReadStatus = -2;
            _rxDump = []b;
            _frameInfo = "";
            _pongCount = 0;
            _scrCount = 0;
            _otherCount = 0;
            _streamRequested = false;
            _approvalPolls = 0;
            setState(ConnState.CONNECTED);
            subscribeTx();
        } else {
            _device = null; _service = null; _rx = null; _tx = null; _rpcChar = null;
            _txQueue = [] as Lang.Array;
            _inputQueued = 0;
            _writePending = false;
            cancelPingTimer();
            if (_approvalTimer != null) { _approvalTimer.stop(); _approvalTimer = null; }
            if (!_stopped) {
                // Record the drop so a flash-then-revert is unambiguous on screen: if the mirror
                // vanishes because the LINK dropped (not because the frame aged), this shows it.
                _disconnects += 1;
                diag("DISCONNECTED #" + _disconnects + " after scr=" + _scrCount + " rx=" + _rxBytes + "b");
                if (_scrCount == 0 && _rxFrames == 0) {
                    // Nothing ever arrived and the Flipper closed the link: that is what a Deny on
                    // the Flipper's approval prompt looks like from here. Reconnecting would just
                    // prompt again, so stop and hand the decision back to the user.
                    _refused = true;
                    setState(ConnState.DEGRADED);
                    diag("Flipper closed the link | denied on the Flipper? | ENTER: choose device");
                    return;
                }
                setState(ConnState.LOST);
                scheduleReconnect();
            } else {
                setState(ConnState.IDLE);
            }
        }
    }

    function subscribeTx() as Void {
        if (_tx == null) { diag("TX characteristic missing"); setState(ConnState.DEGRADED); return; }
        var cccd = _tx.getDescriptor(Ble.cccdUuid());
        if (cccd == null) { diag("TX CCCD missing"); setState(ConnState.DEGRADED); return; }
        cccd.requestWrite(CCCD_NOTIFY);
    }

    function onDescriptorWrite(descriptor, status) as Void {
        if (status == Ble.STATUS_SUCCESS) {
            diag("notifications enabled");
            // Read the Flipper's RPC-status characteristic first: it tells us whether the RPC
            // session actually opened (1) or not (0), which is the difference between "our writes
            // aren't understood" and "the Flipper never wired RX to RPC". Then ping.
            readRpcStatus();
        } else {
            diag("CCCD write failed " + status);
            setState(ConnState.DEGRADED);
        }
    }

    function readRpcStatus() as Void {
        if (_rpcChar != null) {
            try { _rpcChar.requestRead(); return; } catch (ex) { }
        }
        sendPing();
    }

    function onCharacteristicRead(characteristic, status, value) as Void {
        _rpcReadStatus = status;
        _rpcVal = (value != null && value.size() > 0) ? (value[0] & 0xff) : -1;
        if (_rpcVal == 0 && _approvalPolls < APPROVAL_POLL_MAX) {
            // RPC session not open. Under Open BLE Pairing the Flipper holds the link while it asks
            // its user whether to allow this watch; anything we send now is dropped. Wait for the
            // status to flip to 1 rather than spending the ping budget.
            _approvalPolls += 1;
            if (_approvalPolls == 1 || (_approvalPolls % 5) == 0) {
                diag("waiting for approval on the Flipper...");
            }
            if (_approvalTimer != null) { _approvalTimer.stop(); }
            _approvalTimer = new Timer.Timer();
            _approvalTimer.start(method(:readRpcStatus), APPROVAL_POLL_MS, false);
            return;
        }
        if (_approvalTimer != null) { _approvalTimer.stop(); _approvalTimer = null; }
        diag("RPC status char=" + _rpcVal + " (rd st=" + status + ")");
        sendPing();
    }

    function sendPing() as Void {
        if (_rx == null) { return; }
        _pingAttempts += 1;
        writeRx(Protocol.buildPing(null));
        armPingTimer();
    }

    function onCharacteristicWrite(characteristic, status) as Void {
        _lastWriteStatus = status;
        if (status == Ble.STATUS_SUCCESS) { _txAcks += 1; }
        // Previous operation finished → a queued frame can go out now.
        _writePending = false;
        pumpWrites();
    }

    // Inbound bytes (fragmented) → reassembler. ONLY feed data that actually came from the TX
    // characteristic; a notification from any other characteristic (flow control, RPC status)
    // fed into the reassembler would corrupt/desync the frame stream.
    function onCharacteristicChanged(characteristic, value) as Void {
        var isTx = false;
        try {
            var u = characteristic.getUuid();
            isTx = (u != null) && u.equals(Ble.stringToUuid(CHAR_TX_UUID));
        } catch (ex) { isTx = true; }   // if we can't tell, assume TX (previous behaviour)
        if (!isTx) { _nonTxNotifs += 1; return; }

        if (value != null) {
            _rxBytes += value.size();
            if (_indSizes == null) { _indSizes = []; }
            if (_indSizes.size() < 24) { _indSizes.add(value.size()); }
        }
        _reader.feed(value);
    }

    // One complete PB.Main body from the reassembler.
    function onFrameBody(body as Lang.ByteArray) as Void {
        _rxFrames += 1;
        var m = PBMain.decode(body);
        // Record the first frame's decode so the screen explains why a pong isn't recognised:
        // body hex, top-level field, whether it decoded as a pong / a screen frame.
        if (_frameInfo.equals("")) {
            var topField = (body.size() > 0) ? ((body[0] & 0xff) >> 3) : -1;
            _frameInfo = "f[" + hexPreview(body, 10) + "]fld" + topField
                       + (m[:isPong] ? " PONG" : "") + (m[:frame] != null ? " SCR" : "")
                       + " st" + m[:status];
        }
        if (m[:isPong]) {
            _pongCount += 1;
            cancelPingTimer();
            diag("PONG ok p=" + _pongCount + " -> start stream");
            if (_state != ConnState.STREAMING) { startStream(); }
            return;
        }
        if (m[:frame] != null) {
            var frm = m[:frame] as Lang.ByteArray;
            // The Flipper's framebuffer is ALWAYS exactly 1024 bytes (u8g2 16x8 tiles). Anything
            // else means this "frame" came from a mis-parsed / desynced stream - reject it rather
            // than render garbage, so only intact frames reach the screen.
            if (frm.size() != Framebuffer.SIZE) {
                _badFrames += 1;
                return;
            }
            _scrCount += 1;
            cancelPingTimer();               // real frames arriving → link is live
            _seenLabels = null;              // free scan-phase buffer
            setState(ConnState.STREAMING);
            // DIAGNOSTIC: per-page non-zero byte counts (8 pages of 128 bytes). A normal top-text
            // screen is like "45,0,0,0,0,0,0,0"; content spread across pages = shear/corruption.
            if (_onDiag != null) {
                _onDiag.invoke("ok=" + _scrCount + " bad=" + _badFrames + " | PG " + pageCounts(frm));
            }
            // Frame-rate over a rolling window, then publish link telemetry to the view.
            var tnow = System.getTimer();
            _fpsWindowFrames += 1;
            if (_fpsWindowTick == 0) { _fpsWindowTick = tnow; }
            var span = tnow - _fpsWindowTick;
            if (span >= 3000) {
                _fps10 = (_fpsWindowFrames * 10000) / span;
                _fpsWindowTick = tnow;
                _fpsWindowFrames = 0;
            }
            if (_onStats != null) { _onStats.invoke(_rssi, _inputSent, _rxBytes, _fps10); }

            // Render (throttled ~1/s - drawing every frame overloads the watch).
            var now = System.getTimer();
            if (_onFrame != null && (now - _lastRenderTick) >= 1000) {
                _lastRenderTick = now;
                _onFrame.invoke(frm);
            }
            return;
        }
        // Neither pong nor screen frame. These arrive in floods (empty len=0 frames from the
        // stream), and calling diag() -> requestUpdate() on each one re-renders the whole screen
        // dozens of times per second and crashes the app. Count them but DO NOT touch the UI.
        _otherCount += 1;
    }

    // ---- stream control ----
    function startStream() as Void {
        writeRx(Protocol.buildEmptyContent(Protocol.MAIN_GUI_START_STREAM)); // field 20
        if (!_streamRequested) {
            _streamRequested = true;
            startStreamWatchdog();
        }
    }

    // Samples RX byte flow on an interval (NOT per packet) while we wait for the first screen
    // frame, so we can see whether bytes climb toward ~1030 (frame arriving) or stall.
    function startStreamWatchdog() as Void {
        if (_streamWatchdog != null) { _streamWatchdog.stop(); }
        _streamWatchdog = new Timer.Timer();
        _streamWatchdog.start(method(:onStreamWatchdog), 2000, true);
    }
    function onStreamWatchdog() as Void {
        // Stop once a frame is decoded so it no longer overwrites the "PG ..." per-page diagnostic.
        if (_state == ConnState.STREAMING || _stopped || _rx == null) {
            if (_streamWatchdog != null) { _streamWatchdog.stop(); _streamWatchdog = null; }
            return;
        }
        // Until a frame decodes, show progress; onFrameBody then shows the per-page counts ("PG ...").
        diag("wait rx=" + _rxBytes + "b f=" + _rxFrames + " o=" + _otherCount);
    }

    function stopStream() as Void {
        if (_rx != null) {
            writeRx(Protocol.buildEmptyContent(Protocol.MAIN_GUI_STOP_STREAM)); // field 21
        }
    }

    // ---- input ----
    // Button events jump the queue: a screen frame is ~52 packets, so a keypress queued behind
    // one would take seconds to reach the Flipper and feel broken. Input is tiny and latency
    // is what the user actually notices, so it goes to the FRONT (after any in-flight write).
    function sendInput(key as Lang.Number, type as Lang.Number) as Void {
        if (_rx == null) { return; }
        if (_txQueue == null) { _txQueue = [] as Lang.Array; }
        var frame = Protocol.buildInput(key, type);
        // Insert after any already-queued input events (so PRESS/SHORT/RELEASE keep their order)
        // but ahead of stream traffic.
        var at = _inputQueued;
        if (at > _txQueue.size()) { at = _txQueue.size(); }
        var merged = _txQueue.slice(0, at);
        merged.add(frame);
        var tail = _txQueue.slice(at, _txQueue.size());
        for (var i = 0; i < tail.size(); i++) { merged.add(tail[i]); }
        _txQueue = merged;
        _inputQueued = at + 1;
        pumpWrites();
    }

    // Connect IQ allows only ONE outstanding GATT operation. Button handling emits frames
    // back-to-back (e.g. SHORT then RELEASE), so writes are queued and pumped one at a time
    // from onCharacteristicWrite. Dropping a frame (esp. RELEASE) would wedge the Flipper's
    // input state, so overflow drops the *newest* frame only as a last resort.
    function writeRx(frame as Lang.ByteArray) as Void {
        if (_rx == null) { return; }
        if (_txQueue == null) { _txQueue = [] as Lang.Array; }
        if (_txQueue.size() >= TX_QUEUE_MAX) {
            System.println("tx queue full, dropping frame");
            return;
        }
        _txQueue.add(frame);
        pumpWrites();
    }

    function pumpWrites() as Void {
        if (_writePending || _rx == null || _txQueue == null || _txQueue.size() == 0) { return; }
        var frame = _txQueue[0] as Lang.ByteArray;
        try {
            // WRITE_TYPE_WITH_RESPONSE (=0): the Flipper ATT-acks each write via
            // onCharacteristicWrite, which both proves the bytes landed and pumps the next frame.
            // (WRITE_TYPE_DEFAULT is write-without-response - no ack, and it wedges this queue.)
            _rx.requestWrite(frame, { :writeType => Ble.WRITE_TYPE_WITH_RESPONSE });
            _writePending = true;
            _txQueue = _txQueue.slice(1, _txQueue.size());
            if (_inputQueued > 0) {
                _inputQueued -= 1;                       // a prioritised input frame left the queue
                _inputSent += 1;
                if (_onInputSent != null) { _onInputSent.invoke(); }
            }
        } catch (ex) {
            // Another op (e.g. the CCCD write) still in flight; onCharacteristicWrite /
            // onDescriptorWrite will pump again.
            System.println("rx write busy: " + ex.getErrorMessage());
        }
    }

    // ---- timers ----
    function armPingTimer() as Void {
        cancelPingTimer();
        _pingTimer = new Timer.Timer();
        _pingTimer.start(method(:onPingTimeout), PING_TIMEOUT_MS, false);
    }
    function cancelPingTimer() as Void {
        if (_pingTimer != null) { _pingTimer.stop(); _pingTimer = null; }
    }
    // No pong arrived in time. Report what (if anything) the Flipper sent back, then escalate:
    // retry the ping a few times, then fall back to starting the screen stream directly (the
    // ping is only a liveness probe - the stream is what we actually want, and it may work even
    // if the ping does not). Only after all that, with nothing received, do we declare DEGRADED.
    function onPingTimeout() as Void {
        _pingTimer = null;
        if (_state == ConnState.STREAMING) { return; } // already live
        var dumpHex = (_rxDump != null) ? hexPreview(_rxDump, 32) : "";
        var info = _frameInfo.equals("") ? ("raw[" + dumpHex + "]") : _frameInfo;
        if (_pingAttempts < MAX_PING_ATTEMPTS) {
            diag("rx=" + _rxBytes + "b/" + _rxFrames + "f " + info + " r" + _pingAttempts);
            sendPing();
            return;
        }
        if (_pingAttempts == MAX_PING_ATTEMPTS) {
            // Ping unanswered - try the stream anyway and give it one more timeout window.
            diag("no pong; stream rx=" + _rxBytes + "b tx=" + _txAcks + "ack");
            _pingAttempts += 1;
            startStream();
            armPingTimer();
            return;
        }
        // rpcCh tells the story: rpcCh=1 → RPC session active on the Flipper, so writes reach a
        // live RPC but produce no reply (our frame/response path). rpcCh=0 → session never opened.
        // rpcCh=-1/rd!=0 → the status char couldn't be read (permission/profile).
        diag("rx=" + _rxBytes + "b/" + _rxFrames + "f " + info + " rpcCh=" + _rpcVal);
        setState(ConnState.DEGRADED);
    }

    function scheduleReconnect() as Void {
        if (_reconnectTimer != null) { _reconnectTimer.stop(); }
        _reconnectTimer = new Timer.Timer();
        _reconnectTimer.start(method(:onReconnect), RECONNECT_MS, false);
    }
    function onReconnect() as Void {
        _reconnectTimer = null;
        if (!_stopped) { beginScan(); }
    }
}
