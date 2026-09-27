using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.System;

// Renders the mirrored Flipper screen, or a legible status when not live. Never shows a stale
// frame as if it were live: once the link leaves STREAMING, the last frame is dimmed and the
// state is overlaid.
class FlipperRemoteView extends WatchUi.View {
    var _frame = null;                 // last framebuffer bytes (ByteArray) or null
    var _state = ConnState.IDLE;
    var _diag = "not started";
    var _lastFrameTick = 0;
    const STALE_MS = 1500;             // a live frame older than this is treated as stale

    function initialize() {
        View.initialize();
    }

    // Coming back from anything the system drew over us (widget/controls menu): the screen holds
    // pixels this app never painted, and each slice erases only its own band, so force one full
    // wipe and repaint the whole frame.
    function onShow() as Void {
        _needFullClear = true;
        if (_frame != null) { _pass = 0; }
        WatchUi.requestUpdate();
    }

    function setState(s as Lang.Number) as Void {
        _state = s;
        WatchUi.requestUpdate();
    }

    function setDiag(message as Lang.String) as Void {
        _diag = message;
        WatchUi.requestUpdate();
    }

    // --- telemetry shown in the dead space below the mirror ---
    var _rssi = 0;          // link signal strength (dBm)
    var _txCount = 0;       // input frames sent
    var _rxKb = 0;          // kilobytes received
    var _fps10 = 0;         // frames per second x10 (avoids float formatting)

    function setStats(rssi as Lang.Number, txCount as Lang.Number,
                      rxBytes as Lang.Number, fps10 as Lang.Number) as Void {
        _rssi = rssi;
        _txCount = txCount;
        _rxKb = rxBytes / 1024;
        _fps10 = fps10;
        // Deliberately no requestUpdate(): stats arrive with every packet, and repainting the
        // screen for each one starved the mirror render. They ride along with the next frame.
    }

    // --- pending keypress queue shown in the dead space above the mirror ---
    // The link is slow, so the mirror can lag a keypress by seconds. Echoing the queued presses
    // immediately is the difference between "the buttons don't work" and "it's working, just busy".
    var _pending = [] as Lang.Array;   // Array<String> of arrow/label glyphs, oldest first

    function pushPending(label as Lang.String) as Void {
        _pending.add(label);
        while (_pending.size() > 8) { _pending = _pending.slice(1, _pending.size()); }
        WatchUi.requestUpdate();
    }

    function popPending() as Void {
        if (_pending.size() > 0) { _pending = _pending.slice(1, _pending.size()); }
        WatchUi.requestUpdate();
    }

    // --- sliced rendering with double buffering ---
    // The frame is drawn in PASSES slices across consecutive onUpdate calls so no single call
    // trips the render watchdog. The reason the bottom of the screen used to freeze is that a
    // newly arrived frame reset the pass counter mid-render, so the lower slices of the frame
    // being drawn were never painted. Now a frame that arrives mid-render waits in _pendingFrame
    // and is swapped in only once the current one has been drawn in full.
    const PASSES = 8;
    const ROWS_PER_PASS = 8;              // HEIGHT / PASSES
    var _pass = PASSES;                   // next slice to draw; == PASSES means idle/complete
    var _pendingFrame = null;             // newest frame, waiting for the current render to finish
    var _needFullClear = true;            // wipe the whole Dc once when switching off the status screen
    var _axis = InputMap.AXIS_VERTICAL;   // which way the UP/DOWN buttons currently move

    function setAxis(axis as Lang.Number) as Void {
        _axis = axis;
        WatchUi.requestUpdate();
    }

    // Everything drawn around the mirror: a white frame marking the Flipper's screen edge, the
    // pending-keypress strip above it, telemetry below it, and the axis hints on the left.
    // The frame sits OUTSIDE the image rect so it never eats into the mirrored pixels; on a round
    // screen its corners may be clipped, which is fine - the edges are what convey the boundary.
    function drawChrome(dc as Graphics.Dc) as Void {
        var f = Framebuffer.fit(dc.getWidth(), dc.getHeight());
        var s = f[0]; var ox = f[1]; var oy = f[2];
        var w = Framebuffer.scaledWidth(s);
        var h = Framebuffer.scaledHeight(s);

        // White border, 2 px, drawn just outside the image so it costs no image area. The app is
        // monochrome like the Flipper screen it mirrors; the only colour left is the keypress
        // glyphs, where it carries meaning.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRectangle(ox - 3, oy - 3, w + 6, h + 6);
        dc.setPenWidth(1);

        drawPendingStrip(dc, oy - 6);
        drawStats(dc, oy + h + 6);
        drawAxisHints(dc);
    }

    // Horizontal strip of queued keypresses above the mirror - immediate feedback while the
    // (slow) link catches up.
    function drawPendingStrip(dc as Graphics.Dc, bottomY as Lang.Number) as Void {
        var y0 = bottomY - 20;
        if (y0 < 0) { y0 = 0; }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, y0, dc.getWidth(), 20);
        if (_pending.size() == 0) { return; }
        var cx = dc.getWidth() / 2;
        var step = 18;
        var startX = cx - ((_pending.size() - 1) * step) / 2;
        var y = bottomY - 10;
        if (y < 4) { y = 4; }
        dc.setColor(0xFF8C00, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < _pending.size(); i++) {
            dc.drawText(startX + i * step, y, Graphics.FONT_XTINY, _pending[i],
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // Frame rate only. This used to also carry RSSI, kB and key count, but every glyph here is
    // drawn on the watch's UI thread and competes with the mirror render. Frame rate is kept
    // because it is the number the speed work is being measured against - once that is settled
    // this whole strip can go.
    function drawStats(dc as Graphics.Dc, topY as Lang.Number) as Void {
        var y = topY + 8;
        if (y > dc.getHeight() - 10) { y = dc.getHeight() - 10; }
        // Anchored at 80% of the width rather than centred, so it sits off to the right and
        // leaves the middle of the bottom margin clear.
        var x = dc.getWidth() * 80 / 100;
        var line = (_fps10 / 10) + "." + (_fps10 % 10) + "fps";
        var tw = dc.getTextWidthInPixels(line, Graphics.FONT_XTINY) + 8;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(x - tw / 2, y - 9, tw, 18);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, line,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Arrow hints drawn against the LEFT edge, next to the two physical direction buttons, so it
    // is obvious what UP/DOWN will do right now (LIGHT toggles). Mirrors how Garmin's own map view
    // labels its buttons.
    function drawAxisHints(dc as Graphics.Dc) as Void {
        // On a touchscreen directions are swipes; the button-axis hints would only confuse.
        var touch = false;
        try { touch = System.getDeviceSettings().isTouchScreen; } catch (ex) { touch = false; }
        if (touch) { return; }
        var horizontal = (_axis == InputMap.AXIS_HORIZONTAL);
        var h = dc.getHeight();
        var x = 12;
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        // upper button hint at ~1/3 height, lower at ~2/3 - roughly where UP/DOWN sit
        dc.drawText(x, h * 38 / 100, Graphics.FONT_SMALL, horizontal ? "<" : "^",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x, h * 62 / 100, Graphics.FONT_SMALL, horizontal ? ">" : "v",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function setFrame(bytes as Lang.ByteArray) as Void {
        _lastFrameTick = System.getTimer();
        if (_frame == null || _pass >= PASSES) {
            // Idle: start rendering this frame immediately.
            _frame = bytes;
            _pendingFrame = null;
            _pass = 0;
        } else {
            // Mid-render: never disturb the frame being drawn, or its lower slices are lost.
            // Keep only the newest pending frame - older ones are already obsolete.
            _pendingFrame = bytes;
        }
        WatchUi.requestUpdate();
    }

    // Minimal string split (Monkey C has no String.split). Splits _diag on the list delimiter.
    function splitBy(s as Lang.String, sep as Lang.String) as Lang.Array {
        var out = [] as Lang.Array;
        var rest = s;
        var idx = rest.find(sep);
        while (idx != null) {
            out.add(rest.substring(0, idx));
            rest = rest.substring(idx + sep.length(), rest.length());
            idx = rest.find(sep);
        }
        out.add(rest);
        return out;
    }

    // We are "showing the mirror" whenever the link is STREAMING and we have a frame - regardless
    // of frame age. The Flipper only emits a frame when its screen changes, so a static menu is a
    // valid, current mirror, not a stale one. We only fall back to the status overlay when the
    // link itself has left STREAMING (connecting, degraded, reconnecting, idle).
    function isLive() as Lang.Boolean {
        return _state == ConnState.STREAMING && _frame != null;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        // Render the (size-validated) framebuffer, then the chrome around it.
        if (_frame != null && _frame.size() == Framebuffer.SIZE) {
            if (_pass < PASSES) {
                try {
                    var y0 = _pass * ROWS_PER_PASS;
                    // Clear only on the first slice; later slices compose onto the same screen.
                    // Each slice erases its own band, so only the very first frame drawn after
                    // the status screen needs the whole Dc wiped.
                    Framebuffer.draw(dc, _frame, Graphics.COLOR_WHITE, Graphics.COLOR_BLACK,
                        y0, y0 + ROWS_PER_PASS, _needFullClear);
                    _needFullClear = false;
                    _pass += 1;
                } catch (ex) {
                    _pass = PASSES;         // give up on this frame rather than looping on it
                    _diag = "draw err: " + ex.getErrorMessage();
                }
            }
            // Chrome costs several text draws; doing it on each of the 4 slices quadrupled that
            // for no benefit, since the chrome area is untouched by the slice repaints.
            if (_pass >= PASSES) { drawChrome(dc); }
            if (_pass < PASSES) {
                WatchUi.requestUpdate();            // keep going: more slices of this frame
            } else if (_pendingFrame != null) {
                _frame = _pendingFrame;             // frame complete: take the queued one
                _pendingFrame = null;
                _pass = 0;
                WatchUi.requestUpdate();
            }
            return;
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        _needFullClear = true;      // next frame render starts from a screen we did not paint

        var msg = ConnState.label(_state);
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, 40, Graphics.FONT_XTINY, msg, Graphics.TEXT_JUSTIFY_CENTER);
        // Diag is " | "-separated; draw each part on its own line.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var parts = splitBy(_diag, " | ");
        var y = dc.getHeight() / 2 - 30;
        for (var i = 0; i < parts.size() && i < 8; i++) {
            dc.drawText(dc.getWidth() / 2, y, Graphics.FONT_XTINY, parts[i], Graphics.TEXT_JUSTIFY_CENTER);
            y += 16;
        }
    }
}
