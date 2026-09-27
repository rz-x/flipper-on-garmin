using Toybox.Application;
using Toybox.WatchUi;
using Toybox.Lang;
using Toybox.System;

class FlipperRemoteApp extends Application.AppBase {
    var _client = null;
    var _view = null;
    var _input = null;
    var _picker = null;      // DevicePickerView while it is on screen, else null

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Lang.Dictionary or Null) as Void {
        build();
    }

    function build() as Void {
        _view = new FlipperRemoteView();
        _client = new FlipperBleDelegate(_view.method(:setState), _view.method(:setFrame), _view.method(:setDiag),
                _view.method(:setStats), _view.method(:popPending));
        _client.setCandidatesCallback(method(:onCandidates));
        _input = new FlipperInputDelegate(_client, method(:onExit), _view.method(:setAxis),
                _view.method(:pushPending), method(:openPicker));
    }

    // Scan results changed. Feed the picker if it is open; open it when there is something to
    // choose and no remembered device to connect to on its own (or when forced).
    function onCandidates(list as Lang.Array, force as Lang.Boolean) as Void {
        if (_picker != null) { _picker.setItems(list); return; }
        var hasFlipper = false;
        for (var i = 0; i < list.size(); i++) { if (list[i][:flipper]) { hasFlipper = true; break; } }
        if (force || hasFlipper) { openPicker(); }
    }

    function openPicker() as Void {
        if (_picker != null) { return; }
        if (_client.getState() != ConnState.SCANNING) { _client.requestPicker(); }
        _picker = new DevicePickerView();
        _picker.setPreferred(_client.remembered());
        _picker.setItems(_client.candidates());
        WatchUi.pushView(_picker, new DevicePickerDelegate(_picker, method(:onPick), method(:closePicker)), WatchUi.SLIDE_UP);
    }

    function onPick(item as Lang.Dictionary) as Void {
        closePicker();
        _client.connectTo(item);
    }

    function closePicker() as Void {
        if (_picker == null) { return; }
        _picker = null;
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }

    function onStop(state as Lang.Dictionary or Null) as Void {
        if (_client != null) { _client.stop(); }
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        if (_view == null) { build(); }
        if (_client != null) { _client.start(); }
        if (_input == null) { return [ _view ]; }
        return [ _view, _input ];
    }

    // Long-hold BACK asked to leave the app.
    function onExit() as Void {
        if (_client != null) { _client.stop(); }
        System.exit();
    }
}
