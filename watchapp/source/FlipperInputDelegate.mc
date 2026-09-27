using Toybox.WatchUi;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.Attention;

// Translates physical button press/release into the Flipper input sequence and relays it
// over RPC. Mirrors the Flipper's own input semantics: a click is PRESS -> SHORT -> RELEASE;
// a hold is PRESS -> LONG -> RELEASE. SHORT vs LONG is decided by hold duration on release.
//
// Two input styles, both always active:
//  - buttons (5-button fenix/Descent family): UP/DOWN move on the current axis, double-tap ENTER
//    flips the axis, ENTER = OK, BACK = BACK, hold BACK = leave.
//  - touch (vivoactive/venu family, two buttons): swipe in a direction = that direction, tap = OK.
//    No axis needed. The physical START and BACK keys keep their button meaning.
class FlipperInputDelegate extends WatchUi.BehaviorDelegate {
    var _client = null;      // FlipperBleDelegate
    var _onExit = null;      // Method() to leave the app
    var _onAxis = null;      // Method(Number) to tell the view which axis is active
    var _onPending = null;   // Method(String) -> view echoes a queued keypress glyph
    var _onPicker = null;    // Method() -> open the device picker (ENTER while not connected)
    var _axis = InputMap.AXIS_VERTICAL;
    var _pressed = null;     // ciqKey -> [flipperKey, startTick]
    var _sawPress = false;   // this device delivers press/release → ignore onKey (avoid double-fire)
    var _okTimer = null;     // pending single-ENTER, held back to see if a second tap follows
    var _awaitingTap = false;
    var _backlightOn = false;   // LIGHT short-press keeps the backlight lit while reading the mirror

    function initialize(client, onExit as Lang.Method, onAxis as Lang.Method,
                        onPending as Lang.Method, onPicker as Lang.Method) {
        BehaviorDelegate.initialize();
        _client = client;
        _onExit = onExit;
        _onAxis = onAxis;
        _onPending = onPending;
        _onPicker = onPicker;
        _pressed = {};
    }

    function getAxis() as Lang.Number { return _axis; }

    function isDriving() as Lang.Boolean {
        var st = _client.getState();
        return st == ConnState.CONNECTED || st == ConnState.STREAMING;
    }

    // Short glyph shown in the pending-keypress strip.
    function glyphFor(fk as Lang.Number) as Lang.String {
        if (fk == Protocol.KEY_UP)    { return "^"; }
        if (fk == Protocol.KEY_DOWN)  { return "v"; }
        if (fk == Protocol.KEY_LEFT)  { return "<"; }
        if (fk == Protocol.KEY_RIGHT) { return ">"; }
        if (fk == Protocol.KEY_OK)    { return "OK"; }
        return "BK";
    }

    // Garmin exits a Connect IQ app on BACK by default. Consume it: a short BACK must reach the
    // Flipper as its own BACK, and only a ~1.5 s hold leaves the app - the same convention Flipper
    // apps use. Returning true here is what stops the system from closing us.
    function onBack() as Lang.Boolean {
        return true;
    }

    // Second, reliable way to flip the axis. KEY_LIGHT is often swallowed by the system (it drives
    // the backlight), so the app may never see it - onMenu is a first-class Garmin behaviour and is
    // always delivered. Either gesture flips between up/down and left/right.
    function onMenu() as Lang.Boolean {
        toggleAxis();
        return true;
    }

    // A short LIGHT press latches the backlight on. The mirror is a dense black-and-white image
    // that is hard to read unlit, and the axis toggle no longer needs this key (double-tap ENTER
    // does that job), so LIGHT is free for the thing it is actually labelled for.
    function toggleBacklight() as Void {
        _backlightOn = !_backlightOn;
        try {
            Attention.backlight(_backlightOn);
        } catch (ex) {
            _backlightOn = false;   // device or firmware refuses app backlight control
        }
    }

    function cancelOkTimer() as Void {
        if (_okTimer != null) { _okTimer.stop(); _okTimer = null; }
        _awaitingTap = false;
    }

    // No second tap arrived: the ENTER press was a plain OK after all.
    function fireOk() as Void {
        _okTimer = null;
        _awaitingTap = false;
        if (_onPending != null) { _onPending.invoke("OK"); }
        _client.sendInput(Protocol.KEY_OK, Protocol.TYPE_PRESS);
        _client.sendInput(Protocol.KEY_OK, Protocol.TYPE_SHORT);
        _client.sendInput(Protocol.KEY_OK, Protocol.TYPE_RELEASE);
    }

    function toggleAxis() as Void {
        _axis = (_axis == InputMap.AXIS_VERTICAL) ? InputMap.AXIS_HORIZONTAL : InputMap.AXIS_VERTICAL;
        if (_onAxis != null) { _onAxis.invoke(_axis); }
    }

    // Send a complete short click (PRESS, SHORT, RELEASE) - what a swipe or tap maps to.
    function click(fk as Lang.Number) as Void {
        if (_onPending != null) { _onPending.invoke(glyphFor(fk)); }
        _client.sendInput(fk, Protocol.TYPE_PRESS);
        _client.sendInput(fk, Protocol.TYPE_SHORT);
        _client.sendInput(fk, Protocol.TYPE_RELEASE);
    }

    // Touch: a swipe is the direction it travels. Only meaningful while driving; otherwise it
    // falls through to the system (e.g. leaving the app with swipe-right).
    function onSwipe(evt as WatchUi.SwipeEvent) as Lang.Boolean {
        if (!isDriving()) { return false; }
        var d = evt.getDirection();
        if (d == WatchUi.SWIPE_UP)    { click(Protocol.KEY_UP);    return true; }
        if (d == WatchUi.SWIPE_DOWN)  { click(Protocol.KEY_DOWN);  return true; }
        if (d == WatchUi.SWIPE_LEFT)  { click(Protocol.KEY_LEFT);  return true; }
        if (d == WatchUi.SWIPE_RIGHT) { click(Protocol.KEY_RIGHT); return true; }
        return false;
    }

    // Touch: a tap is OK. While not connected it opens the picker, like ENTER does.
    function onTap(evt as WatchUi.ClickEvent) as Lang.Boolean {
        if (!isDriving()) {
            if (_onPicker != null) { _onPicker.invoke(); }
            return true;
        }
        click(Protocol.KEY_OK);
        return true;
    }

    function onKeyPressed(evt as WatchUi.KeyEvent) as Lang.Boolean {
        _sawPress = true;
        var k = evt.getKey();
        if (InputMap.isBacklightKey(k)) { toggleBacklight(); return true; }
        var fk = InputMap.toFlipperKey(k, _axis);
        if (fk == null) {
            // Show the raw key code for anything unmapped. Which physical buttons actually reach
            // a Connect IQ app is device-specific and undocumented; this turns it into an
            // observation instead of a guess.
            if (_onPending != null) { _onPending.invoke("k" + k); }
            return false;
        }
        // Not driving a Flipper yet (scanning, or the link was refused/lost): ENTER is "choose a
        // device", not OK. Once streaming it is a plain OK again.
        if (fk == Protocol.KEY_OK && !isDriving()) {
            if (_onPicker != null) { _onPicker.invoke(); }
            return true;
        }
        _pressed[k] = [fk, System.getTimer()];
        if (fk == Protocol.KEY_OK) {
            // Deferred: see onKeyReleased. Sending PRESS now would fire an OK at the Flipper
            // before we can tell a single tap from the double tap that flips the axis.
            return true;
        }
        // Echo the press on screen straight away - the mirror may lag by seconds, and without
        // this the buttons feel dead even though the event is on its way.
        if (_onPending != null) { _onPending.invoke(glyphFor(fk)); }
        _client.sendInput(fk, Protocol.TYPE_PRESS);
        return true;
    }

    function onKeyReleased(evt as WatchUi.KeyEvent) as Lang.Boolean {
        var k = evt.getKey();
        if (InputMap.isBacklightKey(k)) { return true; }
        var rec = _pressed[k];
        if (rec == null) { return false; }
        _pressed.remove(k);
        var fk = rec[0];
        var held = System.getTimer() - rec[1];

        // Long-hold BACK leaves the app so the user is never trapped behind the mapping.
        if (fk == Protocol.KEY_BACK && held >= InputMap.EXIT_HOLD_MS) {
            if (_onExit != null) { _onExit.invoke(); }
            return true;
        }

        // ENTER: single tap = OK, double tap = flip the direction axis. The OK is held back for
        // DOUBLE_TAP_MS so a second tap can cancel it; against a ~3 s frame that delay is nothing.
        // A hold cannot be used here - Garmin takes hold-ENTER for Wallet before the app sees it.
        if (fk == Protocol.KEY_OK) {
            if (_awaitingTap) {
                cancelOkTimer();
                toggleAxis();
            } else {
                _awaitingTap = true;
                _okTimer = new Timer.Timer();
                _okTimer.start(method(:fireOk), InputMap.DOUBLE_TAP_MS, false);
            }
            return true;
        }

        var t = (held >= InputMap.LONG_PRESS_MS) ? Protocol.TYPE_LONG : Protocol.TYPE_SHORT;
        _client.sendInput(fk, t);
        _client.sendInput(fk, Protocol.TYPE_RELEASE);
        return true;
    }

    // Fallback for devices that deliver only onKey (no press/release pair): emit a short click.
    // If onKeyPressed has ever fired, this device uses the press/release path - ignore onKey
    // so a click is not sent twice.
    function onKey(evt as WatchUi.KeyEvent) as Lang.Boolean {
        if (_sawPress) { return false; }
        var k = evt.getKey();
        if (InputMap.isBacklightKey(k)) { toggleBacklight(); return true; }
        var fk = InputMap.toFlipperKey(k, _axis);
        if (fk == null) { return false; }
        _client.sendInput(fk, Protocol.TYPE_PRESS);
        _client.sendInput(fk, Protocol.TYPE_SHORT);
        _client.sendInput(fk, Protocol.TYPE_RELEASE);
        return true;
    }
}
