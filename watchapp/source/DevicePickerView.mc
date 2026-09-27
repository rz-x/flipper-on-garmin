using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.System;

// Lets the user choose WHICH Flipper to drive. Without this the app connected to the first
// advertiser that looked like a Flipper, which with two Flippers in range was a coin toss - and a
// coin toss that could land on someone else's device. The list is fed live from the scan.
//
// Rows are Flippers first. Detection is heuristic (advertised UUID, GAP appearance, name), so a
// Flipper with an unusual BLE name could be missed; the last row therefore expands to every
// device seen, and the user can pick one by hand.
class DevicePickerView extends WatchUi.View {
    var _items = [] as Lang.Array;   // Array<Dictionary> {:name, :rssi, :flipper}
    var _cursor = 0;
    var _showAll = false;
    var _touch = false;
    var _bandTop = 32;
    var _firstRow = 0;   // scroll offset used by the last onUpdate, so taps map to rows
    const ROW_H = 26;

    function initialize() {
        View.initialize();
        try { _touch = System.getDeviceSettings().isTouchScreen; } catch (ex) { _touch = false; }
    }

    // A row label: device name plus signal, truncated so it fits the highlight bar.
    function fitLabel(dc as Graphics.Dc, name as Lang.String, rssi as Lang.Number) as Lang.String {
        var suffix = "  " + rssi;
        var maxW = dc.getWidth() * 68 / 100;
        var nm = name;
        while (nm.length() > 3 &&
               dc.getTextWidthInPixels(nm + suffix, Graphics.FONT_SMALL) > maxW) {
            nm = nm.substring(0, nm.length() - 1);
        }
        if (!nm.equals(name)) { nm = nm.substring(0, nm.length() - 1) + "..."; }
        return nm + suffix;
    }

    // Row index under a tapped y coordinate, or -1 if none (beyond the toggle row).
    function rowAtY(y as Lang.Number) as Lang.Number {
        if (y < _bandTop) { return -1; }
        var r = _firstRow + (y - _bandTop) / ROW_H;
        if (r > visible().size()) { return -1; }
        return r;
    }

    function setCursorAtY(y as Lang.Number) as Lang.Boolean {
        var r = rowAtY(y);
        if (r < 0) { return false; }
        _cursor = r;
        return true;
    }

    var _preferred = null;   // name of the device chosen last time → cursor lands on it
    var _preselected = false;

    function setPreferred(name as Lang.String or Null) as Void { _preferred = name; }

    function setItems(items as Lang.Array) as Void {
        _items = items;
        if (!_preselected && _preferred != null) {
            var vis = visible();
            for (var i = 0; i < vis.size(); i++) {
                if (_preferred.equals(vis[i][:name])) { _cursor = i; _preselected = true; break; }
            }
        }
        var n = visible().size();
        if (_cursor > n) { _cursor = n; }   // n == the "show all" row
        WatchUi.requestUpdate();
    }

    // The rows actually shown: Flippers, plus everything else when expanded.
    function visible() as Lang.Array {
        var out = [] as Lang.Array;
        for (var i = 0; i < _items.size(); i++) {
            if (_items[i][:flipper] || _showAll) { out.add(_items[i]); }
        }
        return out;
    }

    function othersCount() as Lang.Number {
        var c = 0;
        for (var i = 0; i < _items.size(); i++) { if (!_items[i][:flipper]) { c++; } }
        return c;
    }

    function moveCursor(delta as Lang.Number) as Void {
        var last = visible().size();          // index `last` is the show-all/less row
        _cursor += delta;
        if (_cursor < 0) { _cursor = last; }
        if (_cursor > last) { _cursor = 0; }
        WatchUi.requestUpdate();
    }

    // Returns the chosen item, or null if the cursor was on the show-all row (which toggles).
    function select() as Lang.Dictionary or Null {
        var vis = visible();
        if (_cursor >= vis.size()) {
            _showAll = !_showAll;
            _cursor = 0;
            WatchUi.requestUpdate();
            return null;
        }
        return vis[_cursor];
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Build the row labels: devices, then the Flippers-only / other-devices toggle row.
        var vis = visible();
        var rows = [] as Lang.Array;
        for (var i = 0; i < vis.size(); i++) {
            rows.add(fitLabel(dc, vis[i][:name], vis[i][:rssi]));
        }
        var others = othersCount();
        if (_showAll) {
            rows.add("‹ Flippers only");
        } else if (vis.size() == 0) {
            rows.add("Scanning... " + others + " other");
        } else {
            rows.add("Other devices (" + others + ") ›");
        }

        // How many rows fit between the header and footer, and where the block starts so it is
        // vertically centred when it is short (the common case: one or two Flippers).
        var headY = h * 16 / 100;
        var footY = h - h * 12 / 100;
        var bandTop = headY + 14;
        var bandBot = footY - 12;
        var perScreen = (bandBot - bandTop) / ROW_H;
        if (perScreen < 1) { perScreen = 1; }
        var shown = (rows.size() < perScreen) ? rows.size() : perScreen;

        var first = 0;
        if (_cursor >= perScreen) { first = _cursor - perScreen + 1; }
        _firstRow = first;
        // Centre the shown block vertically within the band.
        var blockH = shown * ROW_H;
        _bandTop = bandTop + ((bandBot - bandTop) - blockH) / 2;
        if (_bandTop < bandTop) { _bandTop = bandTop; }

        // Header.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, headY, Graphics.FONT_XTINY, _showAll ? "All devices" : "Choose Flipper",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Rows. The highlight bar is inset well inside the bezel so it is not clipped on round
        // screens; text is centred in it.
        var barW = (w * 74 / 100);
        var barX = cx - barW / 2;
        for (var r = first; r < rows.size() && (r - first) < perScreen; r++) {
            var midY = _bandTop + (r - first) * ROW_H + ROW_H / 2;
            if (r == _cursor) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
                dc.fillRoundedRectangle(barX, midY - ROW_H / 2 + 2, barW, ROW_H - 4, 6);
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            } else {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            }
            dc.drawText(cx, midY, Graphics.FONT_SMALL, rows[r],
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // Footer hint.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footY, Graphics.FONT_XTINY,
            _touch ? "tap = connect" : "OK connect  ·  BACK back",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

    }
}

// Buttons for the picker: UP/DOWN move, ENTER picks, BACK returns to the status screen with the
// scan still running (hold BACK there to leave the app).
class DevicePickerDelegate extends WatchUi.BehaviorDelegate {
    var _view = null;
    var _onPick = null;   // Method(Dictionary item)
    var _onExit = null;   // Method()

    function initialize(view as DevicePickerView, onPick as Lang.Method, onExit as Lang.Method) {
        BehaviorDelegate.initialize();
        _view = view;
        _onPick = onPick;
        _onExit = onExit;
    }

    function onKey(evt as WatchUi.KeyEvent) as Lang.Boolean {
        var k = evt.getKey();
        if (k == WatchUi.KEY_UP)   { _view.moveCursor(-1); return true; }
        if (k == WatchUi.KEY_DOWN) { _view.moveCursor(1);  return true; }
        if (k == WatchUi.KEY_ENTER) {
            var item = _view.select();
            if (item != null && _onPick != null) { _onPick.invoke(item); }
            return true;
        }
        if (k == WatchUi.KEY_ESC) {
            if (_onExit != null) { _onExit.invoke(); }
            return true;
        }
        return false;
    }

    function onBack() as Lang.Boolean {
        if (_onExit != null) { _onExit.invoke(); }
        return true;
    }

    function onSwipe(evt as WatchUi.SwipeEvent) as Lang.Boolean {
        var d = evt.getDirection();
        if (d == WatchUi.SWIPE_UP)   { _view.moveCursor(1);  return true; }
        if (d == WatchUi.SWIPE_DOWN) { _view.moveCursor(-1); return true; }
        return false;
    }

    function onTap(evt as WatchUi.ClickEvent) as Lang.Boolean {
        var xy = evt.getCoordinates();
        if (!_view.setCursorAtY(xy[1])) { return true; }
        var item = _view.select();
        if (item != null && _onPick != null) { _onPick.invoke(item); }
        return true;
    }
}
