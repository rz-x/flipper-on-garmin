using Toybox.Test;
using Toybox.Lang;

// Encode a PB.Main { gui_screen_frame(22) = ScreenFrame { data(1)=<payload>, orientation(2)=o } }
// for decoder round-trip testing. Test-only encoder (the app never sends screen frames).
(:test)
function encodeScreenFrameMain(payload as Lang.ByteArray, orientation as Lang.Number) as Lang.ByteArray {
    var sf = [] as Lang.Array;
    Protocol.encodeVarint(sf, Protocol.tag(1, Protocol.WIRE_LEN)); // data
    Protocol.encodeVarint(sf, payload.size());
    for (var i = 0; i < payload.size(); i++) { sf.add(payload[i]); }
    Protocol.encodeVarint(sf, Protocol.tag(2, Protocol.WIRE_VARINT)); // orientation
    Protocol.encodeVarint(sf, orientation);

    var main = [] as Lang.Array;
    Protocol.encodeVarint(main, Protocol.tag(2, Protocol.WIRE_VARINT)); // command_status
    Protocol.encodeVarint(main, 0);
    Protocol.encodeVarint(main, Protocol.tag(Protocol.MAIN_GUI_SCREEN_FRAME, Protocol.WIRE_LEN));
    Protocol.encodeVarint(main, sf.size());
    for (var i = 0; i < sf.size(); i++) { main.add(sf[i]); }

    var ba = new [main.size()]b;
    for (var i = 0; i < main.size(); i++) { ba[i] = main[i]; }
    return ba;
}

(:test)
function testDecodeScreenFrame(logger as Test.Logger) as Lang.Boolean {
    var payload = new [1024]b;
    for (var i = 0; i < 1024; i++) { payload[i] = (i * 7) & 0xFF; }
    var body = encodeScreenFrameMain(payload, 0);
    var m = PBMain.decode(body);
    Test.assert(m[:frame] != null);
    Test.assertEqualMessage(m[:frame].size(), 1024, "framebuffer size");
    Test.assertEqual(m[:frame][1023], (1023 * 7) & 0xFF);
    Test.assertEqual(m[:orientation], 0);
    return true;
}

(:test)
function testDecodePong(logger as Test.Logger) as Lang.Boolean {
    // PB.Main { system_ping_response(6) = {} }
    var main = [] as Lang.Array;
    Protocol.encodeVarint(main, Protocol.tag(Protocol.MAIN_SYSTEM_PING_RESPONSE, Protocol.WIRE_LEN));
    Protocol.encodeVarint(main, 0);
    var ba = new [main.size()]b;
    for (var i = 0; i < main.size(); i++) { ba[i] = main[i]; }
    var m = PBMain.decode(ba);
    Test.assert(m[:isPong]);
    Test.assert(m[:frame] == null);
    return true;
}

(:test)
function testDecodeHasNextAndUnknownSkip(logger as Test.Logger) as Lang.Boolean {
    // command_id=7, has_next=true, plus an unknown varint field(9) that must be skipped.
    var main = [] as Lang.Array;
    Protocol.encodeVarint(main, Protocol.tag(1, Protocol.WIRE_VARINT)); Protocol.encodeVarint(main, 7);
    Protocol.encodeVarint(main, Protocol.tag(3, Protocol.WIRE_VARINT)); Protocol.encodeVarint(main, 1);
    Protocol.encodeVarint(main, Protocol.tag(9, Protocol.WIRE_VARINT)); Protocol.encodeVarint(main, 12345);
    var ba = new [main.size()]b;
    for (var i = 0; i < main.size(); i++) { ba[i] = main[i]; }
    var m = PBMain.decode(ba);
    Test.assertEqual(m[:commandId], 7);
    Test.assert(m[:hasNext]);
    return true;
}
